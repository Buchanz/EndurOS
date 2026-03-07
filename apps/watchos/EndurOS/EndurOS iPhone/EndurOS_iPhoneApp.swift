//
//  EndurOS_iPhoneApp.swift
//  EndurOS iPhone
//
//  Created by Tyler Buchanan on 2026-03-05.
//

import SwiftUI
import WatchConnectivity
import Combine

@main
struct EndurOS_iPhoneApp: App {
    @StateObject private var sync = PhoneSyncManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sync)
        }
    }
}

@MainActor
final class PhoneSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var queueCount: Int = 0
    @Published private(set) var lastStatus: String = "Waiting for watch data"
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var connectivityStatus: String = "WCSession not activated"
    @Published private(set) var athleteId: String = ""
    @Published private(set) var apiBaseURL: String = ""
    @Published private(set) var recentSessions: [BackendSession] = []

    private let defaultAthleteId = "e00652ef-a2d2-475f-84a1-ed12daa9c971"
    private let defaultAPIBaseURL = "http://localhost:4000/api"
    private let queueKey = "phone_sync_queue_v1"
    private let recentSessionsKey = "phone_recent_sessions_v1"
    private let athleteIdKey = "phone_sync_athlete_id_v1"
    private let apiBaseURLKey = "phone_sync_api_base_url_v1"
    private let appGroupID = "group.com.tylerbuchanan.enduros"
    private var queue: [QueuedSessionUpload] = []
    private var retryTask: Task<Void, Never>?

    override init() {
        super.init()
        restoreSettings()
        restoreQueue()
        restoreRecentSessions()
        activateWatchConnectivity()
        Task {
            await processQueueIfNeeded()
            await refreshSessions()
        }
    }

    func retryNow() {
        retryTask?.cancel()
        retryTask = nil
        Task { await processQueueIfNeeded(force: true) }
    }

    func refreshNow() {
        Task { await refreshSessions() }
    }

    func requestWatchStartWorkout(sportName: String) {
        guard WCSession.isSupported() else {
            lastStatus = "WatchConnectivity not supported"
            return
        }

        let session = WCSession.default
        let envelope: [String: Any] = [
            "type": "start_workout_request_v1",
            "sport": sportName
        ]

        guard session.activationState == .activated else {
            session.activate()
            session.transferUserInfo(envelope)
            lastStatus = "Queued start request for \(sportName)"
            return
        }

        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.lastStatus = "Start request failed: \(error.localizedDescription)"
                }
            }
            lastStatus = "Sent start request for \(sportName)"
        } else {
            session.transferUserInfo(envelope)
            lastStatus = "Watch not reachable, queued start for \(sportName)"
        }
    }

    func updateSyncSettings(athleteId: String, apiBaseURL: String) {
        self.athleteId = athleteId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiBaseURL = normalizedBaseURL(apiBaseURL)
        persistSettings()
        lastStatus = "Sync settings saved"
        retryNow()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.connectivityStatus = "activation=\(activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable)"
            self.lastStatus = "WC activated"
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.connectivityStatus = "activation=\(session.activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable)"
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("[PhoneSync] didReceiveUserInfo")
        handleIncoming(userInfo: userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("[PhoneSync] didReceiveMessage")
        handleIncoming(userInfo: message)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("[PhoneSync] didReceiveFile")
        guard let type = file.metadata?["type"] as? String, type == "session_upload_v1_file" else { return }
        guard let payloadData = try? Data(contentsOf: file.fileURL) else { return }
        handleIncoming(payloadData: payloadData)
    }

    private nonisolated func handleIncoming(userInfo: [String: Any]) {
        guard let type = userInfo["type"] as? String, type == "session_upload_v1" else { return }
        guard let payloadData = userInfo["sessionPayload"] as? Data else { return }
        handleIncoming(payloadData: payloadData)
    }

    private nonisolated func handleIncoming(payloadData: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let payload = try? decoder.decode(WatchSessionUploadPayload.self, from: payloadData) else { return }

        Task { @MainActor in
            upsertLocalSession(from: payload)
            enqueue(payload: payload)
            await processQueueIfNeeded()
        }
    }

    private func activateWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func enqueue(payload: WatchSessionUploadPayload) {
        queue.append(QueuedSessionUpload(payload: payload, retryCount: 0, lastError: nil))
        persistQueue()
        queueCount = queue.count
        lastStatus = "Received session from watch"
    }

    private func processQueueIfNeeded(force: Bool = false) async {
        if isUploading && !force { return }
        guard !queue.isEmpty else { return }
        guard !athleteId.isEmpty else {
            lastStatus = "Missing athlete ID"
            return
        }
        guard !apiBaseURL.isEmpty else {
            lastStatus = "Missing API base URL"
            return
        }

        isUploading = true
        defer { isUploading = false }

        while !queue.isEmpty {
            var current = queue[0]
            do {
                try await uploadSummary(current.payload)
                try await uploadSamples(current.payload)
                queue.removeFirst()
                persistQueue()
                queueCount = queue.count
                lastStatus = "Uploaded session \(current.payload.sessionId.prefix(8))"
                await refreshSessions()
            } catch {
                current.retryCount += 1
                current.lastError = error.localizedDescription
                queue[0] = current
                persistQueue()
                queueCount = queue.count
                let delay = min(300, Int(pow(2.0, Double(max(0, current.retryCount - 1)))) * 5)
                lastStatus = "Upload failed: \(error.localizedDescription). Retrying in \(delay)s"
                scheduleRetry(after: delay)
                break
            }
        }
    }

    private func uploadSummary(_ payload: WatchSessionUploadPayload) async throws {
        let body: [String: Any] = [
            "sessionId": payload.sessionId,
            "athleteId": athleteId,
            "sport": payload.sport,
            "startedAt": isoString(payload.startedAt),
            "endedAt": isoString(payload.endedAt),
            "durationSec": payload.durationSec,
            "distanceKm": payload.distanceKm,
            "activeCalories": payload.activeCalories,
            "totalCalories": payload.totalCalories,
            "averageSpeedKmh": payload.averageSpeedKmh,
            "maxSpeedKmh": payload.maxSpeedKmh,
            "averagePaceMinPerKm": payload.averagePaceMinPerKm as Any,
            "highSpeedDistanceKm": payload.highSpeedDistanceKm,
            "sprintDistanceKm": payload.sprintDistanceKm,
            "sprintCount": payload.sprintCount,
            "accelerationCount": payload.accelerationCount,
            "decelerationCount": payload.decelerationCount
        ]

        var request = URLRequest(url: try url("\(apiBaseURL)/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
    }

    private func uploadSamples(_ payload: WatchSessionUploadPayload) async throws {
        guard !payload.samples.isEmpty else { return }

        let samples = payload.samples.map { s in
            [
                "timestamp": isoString(s.timestamp),
                "latitude": s.latitude,
                "longitude": s.longitude,
                "altitudeM": s.altitudeM,
                "speedKmh": s.speedKmh,
                "horizontalAccuracyM": s.horizontalAccuracyM
            ] as [String: Any]
        }

        let body: [String: Any] = ["samples": samples]

        var request = URLRequest(url: try url("\(apiBaseURL)/sessions/\(payload.sessionId)/samples"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.httpStatus(http.statusCode)
        }
    }

    private func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw SyncError.invalidURL }
        return url
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func persistQueue() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(queue) else { return }

        if let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(data, forKey: queueKey)
        } else {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
    }

    private func persistSettings() {
        if let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(athleteId, forKey: athleteIdKey)
            sharedDefaults.set(apiBaseURL, forKey: apiBaseURLKey)
        } else {
            UserDefaults.standard.set(athleteId, forKey: athleteIdKey)
            UserDefaults.standard.set(apiBaseURL, forKey: apiBaseURLKey)
        }
    }

    private func restoreSettings() {
        let sharedDefaults = UserDefaults(suiteName: appGroupID)
        let storedAthleteId = sharedDefaults?.string(forKey: athleteIdKey)
            ?? UserDefaults.standard.string(forKey: athleteIdKey)
        let storedAPIBaseURL = sharedDefaults?.string(forKey: apiBaseURLKey)
            ?? UserDefaults.standard.string(forKey: apiBaseURLKey)

        athleteId = (storedAthleteId?.isEmpty == false ? storedAthleteId! : defaultAthleteId)
        apiBaseURL = normalizedBaseURL(storedAPIBaseURL?.isEmpty == false ? storedAPIBaseURL! : defaultAPIBaseURL)
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func scheduleRetry(after seconds: Int) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            if Task.isCancelled { return }
            await self.processQueueIfNeeded()
        }
    }

    private func restoreQueue() {
        let stored = UserDefaults(suiteName: appGroupID)?.data(forKey: queueKey)
            ?? UserDefaults.standard.data(forKey: queueKey)
        guard let stored else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        queue = (try? decoder.decode([QueuedSessionUpload].self, from: stored)) ?? []
        queueCount = queue.count
    }

    private func persistRecentSessions() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(recentSessions) else { return }

        if let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(data, forKey: recentSessionsKey)
        } else {
            UserDefaults.standard.set(data, forKey: recentSessionsKey)
        }
    }

    private func restoreRecentSessions() {
        let stored = UserDefaults(suiteName: appGroupID)?.data(forKey: recentSessionsKey)
            ?? UserDefaults.standard.data(forKey: recentSessionsKey)
        guard let stored else { return }

        let decoder = JSONDecoder()
        recentSessions = (try? decoder.decode([BackendSession].self, from: stored)) ?? []
    }

    private func refreshSessions() async {
        guard !athleteId.isEmpty, !apiBaseURL.isEmpty else { return }

        do {
            var request = URLRequest(url: try url("\(apiBaseURL)/athletes/\(athleteId)/sessions"))
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)

            let decoder = JSONDecoder()
            let payload = try decoder.decode(SessionListResponse.self, from: data)
            recentSessions = payload.sessions
            persistRecentSessions()
        } catch {
            lastStatus = "History refresh failed: \(error.localizedDescription)"
        }
    }

    private func upsertLocalSession(from payload: WatchSessionUploadPayload) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let local = BackendSession(
            id: payload.sessionId,
            sport: payload.sport,
            startedAt: iso.string(from: payload.startedAt),
            endedAt: iso.string(from: payload.endedAt),
            durationSec: payload.durationSec,
            distanceKm: payload.distanceKm,
            activeCalories: payload.activeCalories,
            totalCalories: payload.totalCalories,
            averageSpeedKmh: payload.averageSpeedKmh,
            maxSpeedKmh: payload.maxSpeedKmh,
            averagePaceMinPerKm: payload.averagePaceMinPerKm,
            highSpeedDistanceKm: payload.highSpeedDistanceKm,
            sprintDistanceKm: payload.sprintDistanceKm,
            sprintCount: payload.sprintCount,
            accelerationCount: payload.accelerationCount,
            decelerationCount: payload.decelerationCount
        )

        recentSessions.removeAll { $0.id == local.id }
        recentSessions.insert(local, at: 0)
        persistRecentSessions()
    }

    func shareText(for session: BackendSession) -> String {
        [
            "EndurOS Session",
            "Sport: \(session.sport.capitalized)",
            "Started: \(formattedDate(session.startedAt))",
            "Duration: \(formattedDuration(session.durationSec))",
            "Distance: \(String(format: "%.2f", session.distanceKm)) km",
            "Active Calories: \(Int(session.activeCalories))",
            "Avg Speed: \(String(format: "%.1f", session.averageSpeedKmh)) km/h",
            "Max Speed: \(String(format: "%.1f", session.maxSpeedKmh)) km/h"
        ].joined(separator: "\n")
    }

    func formattedDate(_ value: String) -> String {
        guard let date = parseISODate(value) else { return value }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    func formattedDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func parseISODate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: value) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct QueuedSessionUpload: Codable {
    let payload: WatchSessionUploadPayload
    var retryCount: Int
    var lastError: String?
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
}

struct BackendSession: Codable, Identifiable {
    let id: String
    let sport: String
    let startedAt: String
    let endedAt: String
    let durationSec: Double
    let distanceKm: Double
    let activeCalories: Double
    let totalCalories: Double
    let averageSpeedKmh: Double
    let maxSpeedKmh: Double
    let averagePaceMinPerKm: Double?
    let highSpeedDistanceKm: Double?
    let sprintDistanceKm: Double?
    let sprintCount: Int?
    let accelerationCount: Int?
    let decelerationCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case sport
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSec = "duration_sec"
        case distanceKm = "distance_km"
        case activeCalories = "active_calories"
        case totalCalories = "total_calories"
        case averageSpeedKmh = "average_speed_kmh"
        case maxSpeedKmh = "max_speed_kmh"
        case averagePaceMinPerKm = "average_pace_min_per_km"
        case highSpeedDistanceKm = "high_speed_distance_km"
        case sprintDistanceKm = "sprint_distance_km"
        case sprintCount = "sprint_count"
        case accelerationCount = "acceleration_count"
        case decelerationCount = "deceleration_count"
    }
}

private struct SessionListResponse: Codable {
    let sessions: [BackendSession]
}

private enum SyncError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid backend URL"
        case .invalidResponse: return "Invalid network response"
        case .httpStatus(let code): return "Server returned \(code)"
        }
    }
}
