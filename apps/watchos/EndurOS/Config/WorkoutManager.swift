import Foundation
import HealthKit
import Combine
import CoreLocation
import WatchConnectivity

@MainActor
final class WorkoutManager: NSObject, ObservableObject {

    enum SportProfile: String, CaseIterable, Identifiable {
        case fieldHockey
        case football
        case lacrosse
        case rugby
        case running
        case soccer

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .soccer: return "Soccer"
            case .rugby: return "Rugby"
            case .fieldHockey: return "Field Hockey"
            case .lacrosse: return "Lacrosse"
            case .football: return "Football"
            case .running: return "Running"
            }
        }

        var icon: String {
            switch self {
            case .soccer: return "figure.soccer"
            case .rugby: return "figure.rugby"
            case .fieldHockey: return "figure.hockey"
            case .lacrosse: return "figure.lacrosse"
            case .football: return "figure.american.football"
            case .running: return "figure.run"
            }
        }

        var hkActivityType: HKWorkoutActivityType {
            switch self {
            case .running: return .running
            default: return .other
            }
        }

        static func fromIncomingValue(_ value: String) -> SportProfile? {
            let normalized = value
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ")

            switch normalized {
            case "field hockey", "fieldhockey": return .fieldHockey
            case "football", "american football": return .football
            case "lacrosse": return .lacrosse
            case "rugby": return .rugby
            case "running", "run": return .running
            case "soccer": return .soccer
            default:
                return SportProfile.allCases.first { $0.rawValue == normalized }
            }
        }
    }

    enum RunState: Equatable {
        case idle
        case running
        case paused
        case ended
        case error(String)
    }

    // MARK: - Public, UI-facing state

    @Published private(set) var runState: RunState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var selectedSport: SportProfile?

    /// Forwarded metrics from LocationManager (keeps a single source of truth for GPS)
    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var distanceKm: Double = 0
    @Published private(set) var averageSpeedKmh: Double = 0
    @Published private(set) var maxSpeedKmh: Double = 0
    @Published private(set) var highSpeedDistanceKm: Double = 0
    @Published private(set) var sprintDistanceKm: Double = 0
    @Published private(set) var sprintCount: Int = 0
    @Published private(set) var accelerationCount: Int = 0
    @Published private(set) var decelerationCount: Int = 0
    @Published private(set) var currentPaceMinPerKm: Double?
    @Published private(set) var averagePaceMinPerKm: Double?
    @Published private(set) var caloriesKcal: Double = 0
    @Published private(set) var lastSavedSessionID: String?
    @Published private(set) var lastSavedSessionURL: URL?
    @Published private(set) var lastSaveErrorMessage: String?
    @Published private(set) var isUsingMockData: Bool = false
    @Published private(set) var remoteStartSport: SportProfile?

    // MARK: - Dependencies

    private let healthStore = HKHealthStore()
    private let location: LocationManager

    // MARK: - HealthKit workout session

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var healthKitAvailable = HKHealthStore.isHealthDataAvailable()

    // MARK: - Timing

    private var startDate: Date?
    private var accumulatedPauseTime: TimeInterval = 0
    private var pauseBeganAt: Date?

    private var tickCancellable: AnyCancellable?
    private var previousSpeedMps: Double = 0
    private var routePoints: [WorkoutRoutePoint] = []
    private var lastSavedSession: WorkoutSessionRecord?
    private let companionSync = WatchCompanionSync()

    // MARK: - Performance thresholds

    private let highSpeedThresholdMps = 4.0   // 14.4 km/h
    private let sprintThresholdMps = 5.5      // 19.8 km/h
    private let accelerationThresholdMps2 = 2.5
    private let decelerationThresholdMps2 = -2.5

    // MARK: - Init

    init(location: LocationManager) {
        self.location = location
        super.init()

        companionSync.onRemoteStartRequest = { [weak self] sportValue in
            Task { @MainActor in
                self?.handleRemoteStartRequest(sportValue)
            }
        }

        // Mirror location updates into this manager so UI can bind to WorkoutManager only.
        location.$speedKmh
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.speedKmh = v }
            .store(in: &cancellables)

        location.$distanceKm
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.distanceKm = v }
            .store(in: &cancellables)

        location.$latestSample
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self, let sample else { return }
                self.consume(sample: sample)
            }
            .store(in: &cancellables)

        location.$isUsingMockData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.isUsingMockData = enabled
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Permissions

    /// Call once (e.g., onAppear) before starting.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            // Keep app usable without HealthKit session support.
            healthKitAvailable = false
            location.requestPermission()
            return
        }
        healthKitAvailable = true

        let toShare: Set<HKSampleType> = [HKObjectType.workoutType()]
        let toRead: Set<HKObjectType> = []

        do {
            try await healthStore.requestAuthorization(toShare: toShare, read: toRead)
        } catch {
            // Continue with GPS-only session mode if authorization fails.
            healthKitAvailable = false
        }

        // Location permission is handled by LocationManager
        location.requestPermission()
    }

    // MARK: - Controls

    func start(sport: SportProfile) {
        guard case .idle = runState else {
            // If paused, treat start as resume
            if case .paused = runState { resume() }
            return
        }
        selectedSport = sport

        elapsed = 0
        accumulatedPauseTime = 0
        pauseBeganAt = nil
        startDate = Date()
        resetPerformanceMetrics()
        routePoints = []
        lastSaveErrorMessage = nil

        if healthKitAvailable {
            do {
                try startWorkoutSession()
            } catch {
                // Fall back to non-HealthKit mode, but keep workout active in UI.
                session = nil
                builder = nil
                healthKitAvailable = false
            }
        }

        runState = .running
        location.beginWorkoutTracking()
        startTicking()
    }

    func pause() {
        guard case .running = runState else { return }
        pauseBeganAt = Date()
        session?.pause()
        runState = .paused
        location.pauseTracking()
        stopTicking()
    }

    func resume() {
        guard case .paused = runState else { return }
        if let pauseBeganAt {
            accumulatedPauseTime += Date().timeIntervalSince(pauseBeganAt)
        }
        pauseBeganAt = nil
        session?.resume()
        runState = .running
        location.resumeTracking()
        startTicking()
    }

    func stopAndReset() {
        let endedAt = Date()
        let uploadSport = selectedSport?.rawValue ?? "other"
        let uploadActiveCalories = caloriesKcal
        let uploadTotalCalories = caloriesKcal * 1.15
        persistCurrentSessionIfNeeded(endedAt: endedAt)

        if let record = lastSavedSession {
            companionSync.sendSessionToPhone(
                record: record,
                sport: uploadSport,
                activeCalories: uploadActiveCalories,
                totalCalories: uploadTotalCalories
            )
        }

        session?.end()
        builder?.endCollection(withEnd: endedAt) { _, _ in }
        builder?.finishWorkout { _, _ in }

        stopTicking()
        location.endWorkoutTracking()

        session = nil
        builder = nil

        startDate = nil
        accumulatedPauseTime = 0
        pauseBeganAt = nil

        // Reset exported metrics for the UI
        elapsed = 0
        speedKmh = 0
        distanceKm = 0
        averageSpeedKmh = 0
        maxSpeedKmh = 0
        highSpeedDistanceKm = 0
        sprintDistanceKm = 0
        sprintCount = 0
        accelerationCount = 0
        decelerationCount = 0
        currentPaceMinPerKm = nil
        averagePaceMinPerKm = nil
        previousSpeedMps = 0
        caloriesKcal = 0
        routePoints = []
        selectedSport = nil

        // Also reset the underlying location manager values
        location.reset()

        runState = .idle
    }

    func setMockDataEnabled(_ enabled: Bool) {
        location.setMockDataEnabled(enabled)
        if !enabled {
            location.requestPermission()
        }
    }

    func clearRemoteStartRequest() {
        remoteStartSport = nil
    }

    // MARK: - Private helpers

    private func startWorkoutSession() throws {
        let config = HKWorkoutConfiguration()
        config.activityType = selectedSport?.hkActivityType ?? .other
        config.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let builder = session.associatedWorkoutBuilder()

        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

        self.session = session
        self.builder = builder

        session.startActivity(with: Date())
        builder.beginCollection(withStart: Date()) { _, _ in }
    }

    private func startTicking() {
        // 10 Hz elapsed time updates for smooth tenths display.
        tickCancellable?.cancel()
        tickCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard case .running = self.runState else { return }
                guard let startDate = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(startDate) - self.accumulatedPauseTime
                self.refreshDerivedMetrics()
            }
    }

    private func stopTicking() {
        tickCancellable?.cancel()
        tickCancellable = nil
    }

    private func resetPerformanceMetrics() {
        averageSpeedKmh = 0
        maxSpeedKmh = 0
        highSpeedDistanceKm = 0
        sprintDistanceKm = 0
        sprintCount = 0
        accelerationCount = 0
        decelerationCount = 0
        currentPaceMinPerKm = nil
        averagePaceMinPerKm = nil
        previousSpeedMps = 0
        caloriesKcal = 0
    }

    private func consume(sample: LocationSample) {
        guard case .running = runState else { return }

        if sample.speedKmh > maxSpeedKmh {
            maxSpeedKmh = sample.speedKmh
        }

        routePoints.append(
            WorkoutRoutePoint(
                timestamp: sample.timestamp,
                latitude: sample.latitude,
                longitude: sample.longitude,
                altitudeM: sample.altitudeM,
                speedKmh: sample.speedKmh,
                horizontalAccuracyM: sample.horizontalAccuracyM
            )
        )

        if sample.speedMps >= highSpeedThresholdMps {
            highSpeedDistanceKm += sample.deltaDistanceM / 1000.0
        }
        if sample.speedMps >= sprintThresholdMps {
            sprintDistanceKm += sample.deltaDistanceM / 1000.0
        }
        if previousSpeedMps < sprintThresholdMps, sample.speedMps >= sprintThresholdMps {
            sprintCount += 1
        }

        if sample.deltaTimeS > 0 {
            let acceleration = (sample.speedMps - previousSpeedMps) / sample.deltaTimeS
            if acceleration >= accelerationThresholdMps2 {
                accelerationCount += 1
            } else if acceleration <= decelerationThresholdMps2 {
                decelerationCount += 1
            }
        }

        previousSpeedMps = sample.speedMps
        refreshDerivedMetrics()
    }

    private func refreshDerivedMetrics() {
        if elapsed > 0 {
            averageSpeedKmh = (distanceKm / elapsed) * 3600
        } else {
            averageSpeedKmh = 0
        }

        currentPaceMinPerKm = speedKmh > 0 ? (60.0 / speedKmh) : nil
        averagePaceMinPerKm = distanceKm > 0 ? ((elapsed / 60.0) / distanceKm) : nil
        caloriesKcal = max(0, distanceKm * 65.0)
    }

    private func handleRemoteStartRequest(_ sportValue: String) {
        guard runState == .idle else { return }
        guard let sport = SportProfile.fromIncomingValue(sportValue) else { return }
        remoteStartSport = sport
    }

    func exportLastSavedSessionJSON() -> String? {
        guard let record = lastSavedSession else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportLastSavedSessionGPX() -> String? {
        guard let record = lastSavedSession else { return nil }
        return WorkoutSessionStore.gpx(for: record)
    }

    private func persistCurrentSessionIfNeeded(endedAt: Date) {
        guard let startedAt = startDate else { return }
        let activeDurationS = max(0, elapsed)
        guard activeDurationS > 0 || distanceKm > 0 || !routePoints.isEmpty else { return }

        let record = WorkoutSessionRecord(
            id: UUID().uuidString,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDurationS: activeDurationS,
            totalDistanceKm: distanceKm,
            averageSpeedKmh: averageSpeedKmh,
            maxSpeedKmh: maxSpeedKmh,
            highSpeedDistanceKm: highSpeedDistanceKm,
            sprintDistanceKm: sprintDistanceKm,
            sprintCount: sprintCount,
            accelerationCount: accelerationCount,
            decelerationCount: decelerationCount,
            averagePaceMinPerKm: averagePaceMinPerKm,
            routePoints: routePoints
        )

        // Keep record in memory even if file write fails, so companion sync can still send.
        lastSavedSession = record
        lastSavedSessionID = record.id

        do {
            let savedURL = try WorkoutSessionStore.save(record: record)
            lastSavedSessionURL = savedURL
            lastSaveErrorMessage = nil
        } catch {
            lastSaveErrorMessage = "Failed to save session"
        }
    }
}

private final class WatchCompanionSync: NSObject, WCSessionDelegate {
    private var pendingEnvelopes: [[String: Any]] = []
    var onRemoteStartRequest: ((String) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    override init() {
        super.init()
        activate()
    }

    func sendSessionToPhone(record: WorkoutSessionRecord, sport: String, activeCalories: Double, totalCalories: Double) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        let payload = WatchSessionUploadPayload(
            sessionId: record.id,
            sport: sport,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSec: record.activeDurationS,
            distanceKm: record.totalDistanceKm,
            activeCalories: activeCalories,
            totalCalories: totalCalories,
            averageSpeedKmh: record.averageSpeedKmh,
            maxSpeedKmh: record.maxSpeedKmh,
            averagePaceMinPerKm: record.averagePaceMinPerKm,
            highSpeedDistanceKm: record.highSpeedDistanceKm,
            sprintDistanceKm: record.sprintDistanceKm,
            sprintCount: record.sprintCount,
            accelerationCount: record.accelerationCount,
            decelerationCount: record.decelerationCount,
            samples: downsampledSamples(from: record.routePoints, maxCount: 250)
        )

        guard let data = try? encoder.encode(payload) else { return }
        let envelope: [String: Any] = [
            "type": "session_upload_v1",
            "sessionPayload": data
        ]

        guard session.activationState == .activated else {
            pendingEnvelopes.append(envelope)
            session.activate()
            return
        }

        send(envelope: envelope, over: session)
    }

    private func send(envelope: [String: Any], over session: WCSession) {
        print("[WatchSync] send activation=\(session.activationState.rawValue) reachable=\(session.isReachable)")
        // Real-time path when iPhone app is active.
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
        // Guaranteed queued delivery path.
        session.transferUserInfo(envelope)

        // Robust path for larger payloads.
        if let data = envelope["sessionPayload"] as? Data {
            let filename = "session-\(UUID().uuidString).json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? data.write(to: tempURL, options: .atomic)
            session.transferFile(tempURL, metadata: ["type": "session_upload_v1_file"])
        }
    }

    private func downsampledSamples(from points: [WorkoutRoutePoint], maxCount: Int) -> [WatchRouteSample] {
        guard points.count > maxCount else {
            return points.map(WatchRouteSample.init)
        }
        let step = max(1, points.count / maxCount)
        return stride(from: 0, to: points.count, by: step).map { WatchRouteSample(points[$0]) }
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        guard !pendingEnvelopes.isEmpty else { return }
        let envelopes = pendingEnvelopes
        pendingEnvelopes.removeAll()
        for envelope in envelopes {
            send(envelope: envelope, over: session)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleRemoteEnvelope(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleRemoteEnvelope(userInfo)
    }

    private func handleRemoteEnvelope(_ envelope: [String: Any]) {
        guard let type = envelope["type"] as? String, type == "start_workout_request_v1" else { return }
        guard let sport = envelope["sport"] as? String else { return }
        onRemoteStartRequest?(sport)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {}
}

private struct WatchSessionUploadPayload: Codable {
    let sessionId: String
    let sport: String
    let startedAt: Date
    let endedAt: Date
    let durationSec: TimeInterval
    let distanceKm: Double
    let activeCalories: Double
    let totalCalories: Double
    let averageSpeedKmh: Double
    let maxSpeedKmh: Double
    let averagePaceMinPerKm: Double?
    let highSpeedDistanceKm: Double
    let sprintDistanceKm: Double
    let sprintCount: Int
    let accelerationCount: Int
    let decelerationCount: Int
    let samples: [WatchRouteSample]
}

private struct WatchRouteSample: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
    let speedKmh: Double
    let horizontalAccuracyM: Double

    init(_ point: WorkoutRoutePoint) {
        timestamp = point.timestamp
        latitude = point.latitude
        longitude = point.longitude
        altitudeM = point.altitudeM
        speedKmh = point.speedKmh
        horizontalAccuracyM = point.horizontalAccuracyM
    }
}

struct WorkoutRoutePoint: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
    let speedKmh: Double
    let horizontalAccuracyM: Double
}

struct WorkoutSessionRecord: Codable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let activeDurationS: TimeInterval
    let totalDistanceKm: Double
    let averageSpeedKmh: Double
    let maxSpeedKmh: Double
    let highSpeedDistanceKm: Double
    let sprintDistanceKm: Double
    let sprintCount: Int
    let accelerationCount: Int
    let decelerationCount: Int
    let averagePaceMinPerKm: Double?
    let routePoints: [WorkoutRoutePoint]
}

enum WorkoutSessionStore {
    private static let directoryName = "sessions"

    static func save(record: WorkoutSessionRecord) throws -> URL {
        let dir = try sessionsDirectory()
        let url = dir.appendingPathComponent("\(record.id).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func listRecords(limit: Int = 20) -> [WorkoutSessionRecord] {
        guard let dir = try? sessionsDirectory() else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [WorkoutSessionRecord] = []
        for fileURL in sorted.prefix(limit) {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(WorkoutSessionRecord.self, from: data) else {
                continue
            }
            records.append(record)
        }
        return records
    }

    static func gpx(for record: WorkoutSessionRecord) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<gpx version=\"1.1\" creator=\"EndurOS\" xmlns=\"http://www.topografix.com/GPX/1/1\">")
        lines.append("  <trk>")
        lines.append("    <name>EndurOS Session \(record.id)</name>")
        lines.append("    <trkseg>")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for p in record.routePoints {
            let time = iso.string(from: p.timestamp)
            lines.append("      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><ele>\(p.altitudeM)</ele><time>\(time)</time></trkpt>")
        }

        lines.append("    </trkseg>")
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }

    private static func sessionsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
