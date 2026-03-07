import Foundation
import CoreLocation
import Combine

struct LocationSample {
    let timestamp: Date
    let speedMps: Double
    let speedKmh: Double
    let deltaDistanceM: Double
    let deltaTimeS: TimeInterval
    let horizontalAccuracyM: Double
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
}

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var distanceKm: Double = 0
    @Published private(set) var latestSample: LocationSample?
    @Published private(set) var isUsingMockData: Bool = defaultUseMockData

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var isTracking = false
    private var mockTimer: Timer?
    private var mockElapsedS: TimeInterval = 0
    private var mockTimestamp: Date = .now
    private var mockCoordinate = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
    private var mockHeadingRadians: Double = 0

    private static let defaultUseMockData = false

    override init() {
        super.init()

        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func setMockDataEnabled(_ enabled: Bool) {
        guard isUsingMockData != enabled else { return }
        isUsingMockData = enabled
        guard isTracking else { return }
        if enabled {
            manager.stopUpdatingLocation()
            startMockTracking()
        } else {
            stopMockTracking()
            manager.startUpdatingLocation()
        }
    }

    func reset() {
        lastLocation = nil
        speedKmh = 0
        distanceKm = 0
        latestSample = nil
        mockElapsedS = 0
        mockTimestamp = .now
        mockCoordinate = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        mockHeadingRadians = 0
    }

    func beginWorkoutTracking() {
        reset()
        isTracking = true
        if isUsingMockData {
            startMockTracking()
        } else {
            manager.startUpdatingLocation()
        }
    }

    func resumeTracking() {
        // Do not bridge paused movement into active distance.
        lastLocation = nil
        isTracking = true
        if isUsingMockData {
            startMockTracking()
        } else {
            manager.startUpdatingLocation()
        }
    }

    func pauseTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        stopMockTracking()
        lastLocation = nil
        speedKmh = 0
    }

    func endWorkoutTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        stopMockTracking()
        speedKmh = 0
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            process(location: location)
        }
    }

    private func process(location: CLLocation) {
        // Ignore invalid or stale fixes.
        guard location.horizontalAccuracy >= 0 else { return }
        if location.timestamp.timeIntervalSinceNow < -10 { return }

        var deltaDistanceM: Double = 0
        var deltaTimeS: TimeInterval = 0

        if let last = lastLocation {
            deltaTimeS = location.timestamp.timeIntervalSince(last.timestamp)
            if deltaTimeS > 0 {
                let rawDistanceM = location.distance(from: last)
                let impliedSpeedMps = rawDistanceM / deltaTimeS

                // Filter obvious GPS spikes.
                if rawDistanceM > 0,
                   location.horizontalAccuracy <= 30,
                   impliedSpeedMps <= 12 {
                    deltaDistanceM = rawDistanceM
                    distanceKm += rawDistanceM / 1000.0
                }
            }
        }

        let derivedSpeedMps = deltaTimeS > 0 ? (deltaDistanceM / deltaTimeS) : 0
        let rawSpeedMps = location.speed >= 0 ? location.speed : derivedSpeedMps
        let clampedSpeedMps = max(0, min(rawSpeedMps, 12.5))
        speedKmh = clampedSpeedMps * 3.6

        latestSample = LocationSample(
            timestamp: location.timestamp,
            speedMps: clampedSpeedMps,
            speedKmh: clampedSpeedMps * 3.6,
            deltaDistanceM: deltaDistanceM,
            deltaTimeS: deltaTimeS,
            horizontalAccuracyM: location.horizontalAccuracy,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeM: location.altitude
        )

        lastLocation = location
    }

    private func startMockTracking() {
        stopMockTracking()
        mockTimestamp = .now
        mockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.emitMockLocation()
        }
    }

    private func stopMockTracking() {
        mockTimer?.invalidate()
        mockTimer = nil
    }

    private func emitMockLocation() {
        mockElapsedS += 1
        let now = mockTimestamp.addingTimeInterval(1)
        mockTimestamp = now

        // Vary intensity and include periodic sprint windows.
        let baseSpeedMps = 3.2 + (sin(mockElapsedS / 20) * 0.8)
        let sprintBoost: Double = (Int(mockElapsedS) % 45) < 8 ? 2.9 : 0
        let speedMps = max(0.8, baseSpeedMps + sprintBoost)

        let distanceM = speedMps * 1.0
        mockHeadingRadians += 0.02
        let latMeters = cos(mockHeadingRadians) * distanceM
        let lonMeters = sin(mockHeadingRadians) * distanceM
        let nextLat = mockCoordinate.latitude + (latMeters / 111_111.0)
        let nextLon = mockCoordinate.longitude + (lonMeters / (111_111.0 * max(0.1, cos(mockCoordinate.latitude * .pi / 180.0))))
        mockCoordinate = CLLocationCoordinate2D(latitude: nextLat, longitude: nextLon)

        let location = CLLocation(
            coordinate: mockCoordinate,
            altitude: 15,
            horizontalAccuracy: 5,
            verticalAccuracy: 8,
            course: mockHeadingRadians * 180 / .pi,
            speed: speedMps,
            timestamp: now
        )

        process(location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error:", error)
    }
}
