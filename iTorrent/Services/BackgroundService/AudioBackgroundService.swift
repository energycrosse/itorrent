//
//  AudioBackgroundService.swift
//  iTorrent
//
//  Created by Daniil Vinogradov on 05/04/2024.
//

import AVFoundation
import UIKit

/// Keeps the torrent engine eligible for background execution by maintaining the
/// existing iTorrent background-audio session while background work is required.
///
/// UIKit background tasks are used only as short transition/recovery assertions.
/// They are never recursively renewed as an indefinite execution mechanism.
final class AudioBackgroundService: @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var observerTokens: [NSObjectProtocol] = []
    private var monitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var transitionEndTask: Task<Void, Never>?

    private var recoveryAttempt = 0
    private let maximumRecoveryAttempts = 5
    private var stopping = false
}

extension AudioBackgroundService: BackgroundServiceProtocol {
    var isRunning: Bool {
        onMain {
            (player?.isPlaying ?? false) || backgroundTask != .invalid
        }
    }

    func start() -> Bool {
        onMain { startOnMain() }
    }

    func stop() {
        onMain { stopOnMain() }
    }

    func prepare() async -> Bool { true }
}

private extension AudioBackgroundService {
    func startOnMain() -> Bool {
        guard PreferencesStorage.shared.isBackgroundDownloadEnabled,
              BackgroundService.isBackgroundNeeded
        else {
            return false
        }

        stopping = false
        installObserversIfNeeded()
        beginTransitionBackgroundTask(reason: "start")
        BackgroundDiagnostics.shared.setState("starting")

        let started = ensureAudioPlaying(reason: "start")
        if !started {
            scheduleRecovery(reason: "initial start")
        }

        startMonitorIfNeeded()
        return started || backgroundTask != .invalid
    }

    func stopOnMain() {
        stopping = true

        monitorTask?.cancel()
        monitorTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        transitionEndTask?.cancel()
        transitionEndTask = nil

        removeObservers()
        endTransitionBackgroundTask(reason: "stop")

        player?.stop()
        player = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            BackgroundDiagnostics.shared.record("audio session deactivation failed: \(error.localizedDescription)")
        }

        recoveryAttempt = 0
        BackgroundDiagnostics.shared.setRecoveryAttempts(0)
        BackgroundDiagnostics.shared.setAudio(sessionActive: false, playerActive: false)
        BackgroundDiagnostics.shared.setState("inactive")
        BackgroundDiagnostics.shared.record("background audio stopped")
    }

    @discardableResult
    func ensureAudioPlaying(reason: String) -> Bool {
        guard !stopping,
              PreferencesStorage.shared.isBackgroundDownloadEnabled,
              BackgroundService.isBackgroundNeeded
        else {
            return false
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            BackgroundDiagnostics.shared.setAudio(sessionActive: true)

            let audioPlayer: AVAudioPlayer
            if let player {
                audioPlayer = player
            } else {
                guard let url = Bundle.main.url(forResource: "sound", withExtension: "m4a") else {
                    throw NSError(
                        domain: "iTorrent.BackgroundAudio",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "sound.m4a is missing from the application bundle"]
                    )
                }

                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.volume = 0.01
                newPlayer.numberOfLoops = -1
                newPlayer.prepareToPlay()
                player = newPlayer
                audioPlayer = newPlayer
            }

            guard audioPlayer.play() else {
                throw NSError(
                    domain: "iTorrent.BackgroundAudio",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer refused to start"]
                )
            }

            recoveryAttempt = 0
            BackgroundDiagnostics.shared.setRecoveryAttempts(0)
            BackgroundDiagnostics.shared.setAudio(playerActive: true)
            BackgroundDiagnostics.shared.setState("active")
            BackgroundDiagnostics.shared.record("audio keepalive active (\(reason))")

            scheduleTransitionTaskEnd()
            return true
        } catch {
            BackgroundDiagnostics.shared.setAudio(playerActive: false)
            BackgroundDiagnostics.shared.failure("audio start failed (\(reason)): \(error.localizedDescription)")
            return false
        }
    }

    func installObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        )

        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.handleMediaServicesReset()
            }
        )
    }

    func removeObservers() {
        let center = NotificationCenter.default
        observerTokens.forEach(center.removeObserver)
        observerTokens.removeAll()
    }

    func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value)
        else {
            return
        }

        switch type {
        case .began:
            BackgroundDiagnostics.shared.setAudio(sessionActive: false, playerActive: player?.isPlaying ?? false)
            BackgroundDiagnostics.shared.setState("interrupted")
            BackgroundDiagnostics.shared.record("audio interruption began")
            beginTransitionBackgroundTask(reason: "audio interruption")

        case .ended:
            BackgroundDiagnostics.shared.record("audio interruption ended")
            guard BackgroundService.isBackgroundNeeded,
                  PreferencesStorage.shared.isBackgroundDownloadEnabled
            else {
                return
            }

            recoveryTask?.cancel()
            recoveryTask = nil

            if !ensureAudioPlaying(reason: "interruption ended") {
                scheduleRecovery(reason: "interruption ended")
            }

        @unknown default:
            BackgroundDiagnostics.shared.record("unknown audio interruption type")
        }
    }

    func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        BackgroundDiagnostics.shared.record("audio route changed: \(String(describing: reason))")

        guard BackgroundService.isBackgroundNeeded,
              PreferencesStorage.shared.isBackgroundDownloadEnabled,
              !(player?.isPlaying ?? false)
        else {
            return
        }

        beginTransitionBackgroundTask(reason: "route change")
        if !ensureAudioPlaying(reason: "route change") {
            scheduleRecovery(reason: "route change")
        }
    }

    func handleMediaServicesReset() {
        BackgroundDiagnostics.shared.record("audio media services reset")
        player?.stop()
        player = nil
        BackgroundDiagnostics.shared.setAudio(sessionActive: false, playerActive: false)

        guard BackgroundService.isBackgroundNeeded,
              PreferencesStorage.shared.isBackgroundDownloadEnabled
        else {
            return
        }

        beginTransitionBackgroundTask(reason: "media services reset")
        if !ensureAudioPlaying(reason: "media services reset") {
            scheduleRecovery(reason: "media services reset")
        }
    }

    func startMonitorIfNeeded() {
        guard monitorTask == nil else { return }

        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }

                guard !stopping else { return }

                guard PreferencesStorage.shared.isBackgroundDownloadEnabled,
                      BackgroundService.isBackgroundNeeded
                else {
                    stopOnMain()
                    return
                }

                if !(player?.isPlaying ?? false) {
                    BackgroundDiagnostics.shared.setAudio(playerActive: false)
                    BackgroundDiagnostics.shared.record("monitor detected stopped audio player")
                    beginTransitionBackgroundTask(reason: "monitor recovery")
                    scheduleRecovery(reason: "monitor")
                }
            }
        }
    }

    func scheduleRecovery(reason: String) {
        guard !stopping,
              recoveryTask == nil,
              PreferencesStorage.shared.isBackgroundDownloadEnabled,
              BackgroundService.isBackgroundNeeded
        else {
            return
        }

        recoveryAttempt += 1
        BackgroundDiagnostics.shared.setRecoveryAttempts(recoveryAttempt)

        guard recoveryAttempt <= maximumRecoveryAttempts else {
            BackgroundDiagnostics.shared.setState("failed")
            BackgroundDiagnostics.shared.failure("recovery limit reached after \(maximumRecoveryAttempts) attempts")
            endTransitionBackgroundTask(reason: "recovery exhausted")
            return
        }

        let delaySeconds = min(1 << (recoveryAttempt - 1), 16)
        BackgroundDiagnostics.shared.setState("recovering")
        BackgroundDiagnostics.shared.record(
            "recovery attempt \(recoveryAttempt)/\(maximumRecoveryAttempts) in \(delaySeconds)s (\(reason))"
        )
        beginTransitionBackgroundTask(reason: "recovery")

        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }

            guard let self, !stopping else { return }

            let recovered = ensureAudioPlaying(reason: "recovery \(recoveryAttempt)")
            recoveryTask = nil

            if !recovered {
                scheduleRecovery(reason: reason)
            }
        }
    }

    func beginTransitionBackgroundTask(reason: String) {
        guard backgroundTask == .invalid else { return }

        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "iTorrent Background Audio Transition"
        ) { [weak self] in
            guard let self else { return }
            BackgroundDiagnostics.shared.record("UIKit transition background task expired")
            endTransitionBackgroundTask(reason: "expired")
        }

        backgroundTask = identifier
        if identifier == .invalid {
            BackgroundDiagnostics.shared.record("UIKit transition background task was not granted")
        } else {
            BackgroundDiagnostics.shared.record("UIKit transition background task began (\(reason))")
        }
    }

    func scheduleTransitionTaskEnd() {
        transitionEndTask?.cancel()
        transitionEndTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            self?.endTransitionBackgroundTask(reason: "audio established")
        }
    }

    func endTransitionBackgroundTask(reason: String) {
        transitionEndTask?.cancel()
        transitionEndTask = nil

        guard backgroundTask != .invalid else { return }

        let identifier = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        BackgroundDiagnostics.shared.record("UIKit transition background task ended (\(reason))")
    }

    func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }
}
