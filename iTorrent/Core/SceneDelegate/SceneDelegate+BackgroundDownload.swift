//
//  SceneDelegate+BackgroundDownload.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 05.04.2024.
//

import Combine
import LibTorrent
import UIKit

extension SceneDelegate {
    func startBackgroundIfNeeded() {
        if PreferencesStorage.shared.isBackgroundDownloadEnabled, BackgroundService.isBackgroundNeeded {
            BackgroundService.shared.start()
        }
    }

    func stopBackground() {
        BackgroundService.shared.stop()
    }

    var backgroundStateObserverBind: AnyCancellable {
        TorrentService.shared.updateNotifier
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard UIApplication.shared.applicationState != .active else { return }

                if PreferencesStorage.shared.isBackgroundDownloadEnabled,
                   BackgroundService.isBackgroundNeeded
                {
                    if !BackgroundService.shared.isRunning {
                        BackgroundDiagnostics.shared.record("torrent state requested background restart")
                        BackgroundService.shared.start()
                    }
                } else {
                    BackgroundService.shared.stop()
                }
            }
    }
}
