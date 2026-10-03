//
//  AppDelegate+Firebase.swift
//  iTorrent
//
//  Created by Даниил Виноградов on 20.04.2024.
//

import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif

extension AppDelegate {
    func registerFirebase() {
#if canImport(FirebaseCore)
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path)
        else {
            print("Firebase configuration is not bundled; analytics and crash reporting are disabled.")
            return
        }
        FirebaseApp.configure(options: options)
#endif
    }
}
