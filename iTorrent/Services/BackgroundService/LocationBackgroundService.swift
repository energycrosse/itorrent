//
//  LocationBackgroundService.swift
//  iTorrent
//
//  Created by Daniil Vinogradov on 05/04/2024.
//

import CoreLocation

final class LocationBackgroundService: NSObject, @unchecked Sendable {
    override init() {
        super.init()
        locationManager.delegate = self
    }

    private(set) var isRunning: Bool = false

    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private let locationManager = CLLocationManager()
}

extension LocationBackgroundService: BackgroundServiceProtocol {
    func start() -> Bool {
        guard !isRunning else { return true }

        let started = runLocationService()
        isRunning = started

        if started {
            BackgroundDiagnostics.shared.setState("active")
            BackgroundDiagnostics.shared.record("location background service started")
        } else {
            BackgroundDiagnostics.shared.failure("location background service could not start")
        }

        return started
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        isRunning = false
        BackgroundDiagnostics.shared.setState("inactive")
        BackgroundDiagnostics.shared.record("location background service stopped")
    }

    func prepare() async -> Bool {
        var status = locationManager.authorizationStatus

        if status == .notDetermined {
#if !os(visionOS)
            // When-In-Use is sufficient for a location session that starts while the
            // app is in the foreground and is explicitly allowed to continue in the
            // background. This avoids requesting broader "Always" access.
            locationManager.requestWhenInUseAuthorization()
#endif
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
            status = locationManager.authorizationStatus
        }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            BackgroundDiagnostics.shared.record("location permission ready: \(status.rawValue)")
            return true
        case .denied, .restricted:
            BackgroundDiagnostics.shared.failure("location permission denied or restricted")
            return false
        case .notDetermined:
            BackgroundDiagnostics.shared.failure("location permission was not determined")
            return false
        @unknown default:
            BackgroundDiagnostics.shared.failure("unknown location authorization status")
            return false
        }
    }
}

private extension LocationBackgroundService {
    func runLocationService() -> Bool {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            return false
        }

        // iTorrent does not read, persist, or transmit the coordinates. The manager
        // exists only while background torrent execution is requested.
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = false

#if !os(visionOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator =
            PreferencesStorage.shared.isBackgroundLocationIndicatorEnabled
#endif

        locationManager.startUpdatingLocation()
        return true
    }
}

extension LocationBackgroundService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard manager.authorizationStatus != .notDetermined else { return }

            authorizationContinuation?.resume()
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        BackgroundDiagnostics.shared.record(
            "location manager error: \(error.localizedDescription)"
        )
    }

    // Deliberately ignore coordinates. Their delivery keeps the selected
    // background location session active; iTorrent has no use for the values.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {}
}
