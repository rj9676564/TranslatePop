//
//  TranslatePopApp.swift
//  TranslatePop
//
//  Created by laibin on 2026/3/27.
//

import SwiftUI
import SwiftData

@main
struct TranslatePopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(coordinator)
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 760, maxHeight: .infinity)
        }
        .modelContainer(for: TranslationHistoryItem.self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}