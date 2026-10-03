//
//  BackgroundService.swift
//  iTorrent
//
//  Created by Daniil Vinogradov on 05/04/2024.
//

import Combine
import Foundation
import LibTorrent
import UIKit

protocol BackgroundServiceProtocol {
    var isRunning: Bool { get }
    func start() -> Bool
    func stop()
    func prepare() async -> Bool
}

extension BackgroundService {
    enum Mode: Codable {
        case audio
        case location
    }
}

/// Small persistent diagnostic recorder for background execution.
///
/// This intentionally records service state only. Torrent names, file names,
/// trackers, magnet links, and other user content are never written here.
final class BackgroundDiagnostics: @unchecked Sendable {
    static let shared = BackgroundDiagnostics()

    private let lock = NSLock()
    private let eventsKey = "backgroundDiagnostics.events"
    private let maxEvents = 120

    private var state = "inactive"
    private var audioSessionActive = false
    private var audioPlayerActive = false
    private var recoveryAttempts = 0
    private var lastFailure: String?
    private var events: [String] = []

    private init() {
        events = Array(UserDefaults.standard.stringArray(forKey: eventsKey)?.suffix(maxEvents) ?? [])
    }

    func setState(_ newState: String) {
        locked { state = newState }
        record("state=\(newState)")
    }

    func setAudio(sessionActive: Bool? = nil, playerActive: Bool? = nil) {
        locked {
            if let sessionActive { audioSessionActive = sessionActive }
            if let playerActive { audioPlayerActive = playerActive }
        }
    }

    func setRecoveryAttempts(_ count: Int) {
        locked { recoveryAttempts = count }
    }

    func failure(_ message: String) {
        locked { lastFailure = message }
        record("failure: \(message)")
    }

    func record(_ message: String) {
        let line = "\(Self.timestamp()) \(message)"
        locked {
            events.append(line)
            if events.count > maxEvents {
                events.removeFirst(events.count - maxEvents)
            }
            UserDefaults.standard.set(events, forKey: eventsKey)
        }
        print("[BG] \(line)")
    }

    func report(
        serviceRunning: Bool,
        enabled: Bool,
        mode: String,
        appState: String,
        downloadingCount: Int,
        seedingCount: Int,
        backgroundNeeded: Bool,
        backgroundTimeRemaining: TimeInterval
    ) -> String {
        let snapshot = locked {
            (
                state,
                audioSessionActive,
                audioPlayerActive,
                recoveryAttempts,
                lastFailure,
                events
            )
        }

        var lines = [
            "iTorrent Background Diagnostics",
            "Generated: \(Self.timestamp())",
            "Enabled: \(enabled)",
            "Method: \(mode)",
            "Service state: \(snapshot.0)",
            "Service running: \(serviceRunning)",
            "Application state: \(appState)",
            "Background needed: \(backgroundNeeded)",
            "Audio session active: \(snapshot.1)",
            "Audio player active: \(snapshot.2)",
            "Recovery attempts: \(snapshot.3)",
            "Downloading/metadata/checking: \(downloadingCount)",
            "Seeding: \(seedingCount)",
            String(format: "UIKit background time remaining: %.1f", backgroundTimeRemaining),
            "Last failure: \(snapshot.4 ?? "none")",
            "",
            "Recent events:"
        ]
        lines.append(contentsOf: snapshot.5)
        return lines.joined(separator: "\n")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

class BackgroundService: BackgroundServiceProtocol {
    @Published var isRunningPublisher: Bool = false

    public static let shared = BackgroundService()

    var isRunning: Bool { impl.isRunning }

    @discardableResult
    func start() -> Bool {
        guard PreferencesStorage.shared.isBackgroundDownloadEnabled,
              Self.isBackgroundNeeded
        else {
            isRunningPublisher = false
            return false
        }

        let result = impl.start()
        isRunningPublisher = result
        if result {
            BackgroundDiagnostics.shared.record("background service started")
        } else {
            BackgroundDiagnostics.shared.failure("background service could not start")
        }
        return result
    }

    func stop() {
        // Stop unconditionally. An interrupted audio player can report not-running
        // while still owning observers, a UIKit background task, or an audio session.
        impl.stop()
        isRunningPublisher = false
    }

    func prepare() async -> Bool {
        await impl.prepare()
    }

    func applyMode(_ mode: Mode) async -> Bool {
        let shouldResume = isRunning
            && PreferencesStorage.shared.isBackgroundDownloadEnabled
            && Self.isBackgroundNeeded

        impl.stop()

        switch mode {
        case .audio:
            impl = AudioBackgroundService()
        case .location:
            impl = LocationBackgroundService()
        }

        let prepared = await impl.prepare()
        if prepared, shouldResume {
            _ = start()
        }
        return prepared
    }

    var diagnosticsReport: String {
        let snapshots = TorrentService.shared.torrents.values.map(\.snapshot)
        let downloadingCount = snapshots.filter {
            $0.friendlyState == .checkingFiles
                || $0.friendlyState == .checkingResumeData
                || $0.friendlyState == .downloading
                || $0.friendlyState == .downloadingMetadata
        }.count
        let seedingCount = snapshots.filter { $0.friendlyState == .seeding }.count

        let mode: String
        switch PreferencesStorage.shared.backgroundMode {
        case .audio:
            mode = "Audio"
        case .location:
            mode = "Location"
        }

        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:
            appState = "active"
        case .inactive:
            appState = "inactive"
        case .background:
            appState = "background"
        @unknown default:
            appState = "unknown"
        }

        return BackgroundDiagnostics.shared.report(
            serviceRunning: isRunning,
            enabled: PreferencesStorage.shared.isBackgroundDownloadEnabled,
            mode: mode,
            appState: appState,
            downloadingCount: downloadingCount,
            seedingCount: seedingCount,
            backgroundNeeded: Self.isBackgroundNeeded,
            backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining
        )
    }

    private var impl: BackgroundServiceProtocol = AudioBackgroundService()
}

// MARK: Background requirements

extension BackgroundService {
    static var isBackgroundNeeded: Bool {
        TorrentService.shared.torrents.values.contains(where: { $0.snapshot.needBackground })
    }
}

extension TorrentHandle.Snapshot {
    var needBackground: Bool {
        friendlyState == .checkingFiles
            || friendlyState == .checkingResumeData
            || friendlyState == .downloading
            || friendlyState == .downloadingMetadata
            || (friendlyState == .seeding && PreferencesStorage.shared.isBackgroundSeedingEnabled)
    }
}
