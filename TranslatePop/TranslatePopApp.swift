//
//  TranslatePopApp.swift
//  TranslatePop
//
//  Created by laibin on 2026/3/27.
//

import SwiftUI

@main
struct TranslatePopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(coordinator)
                .frame(minWidth: 720, minHeight: 620)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
