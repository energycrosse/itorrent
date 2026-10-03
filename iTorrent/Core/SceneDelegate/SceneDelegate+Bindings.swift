//
//  SceneDelegate+Bindings.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 05.04.2024.
//

import Combine
import UIKit

extension SceneDelegate {
    var tintColorBind: AnyCancellable {
        PreferencesStorage.shared.$tintColor.sink { [unowned self] color in
            window?.tintColor = color
        }
    }

    var appAppearanceBind: AnyCancellable {
        PreferencesStorage.shared.$appAppearance.sink { [unowned self] appearance in
            guard let window else { return }
            window.overrideUserInterfaceStyle = appearance
        }
    }

    var backgroundDownloadModeBind: AnyCancellable {
        Publishers.CombineLatest(PreferencesStorage.shared.$backgroundMode, PreferencesStorage.shared.$isBackgroundDownloadEnabled)
            .receive(on: DispatchQueue.main)
            .sink { mode, isBackgroundDownloadEnabled in
                guard isBackgroundDownloadEnabled else {
                    BackgroundService.shared.stop()
                    return
                }

                Task { @MainActor in
                    // Fall back to audio if a permission-gated mode cannot prepare.
                    if await !BackgroundService.shared.applyMode(mode) {
                        PreferencesStorage.shared.backgroundMode = .audio
                        return
                    }

                    if UIApplication.shared.applicationState != .active,
                       BackgroundService.isBackgroundNeeded
                    {
                        BackgroundService.shared.start()
                    }
                }
            }
    }
}
