import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let menu: NSMenu

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.menu = NSMenu()
        super.init()
        configurePopover()
        configureMenu()
        configureStatusItem()
    }

    func updateIcon(name: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "TranslatePop")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(coordinator)
                .frame(width: 320)
        )
    }

    private func configureMenu() {
        let settingsItem = NSMenuItem(title: "打开设置", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: coordinator.menuBarIconName, accessibilityDescription: "TranslatePop")
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc
    private func openSettings() {
        coordinator.openSettingsWindow()
    }

    @objc
    private func quitApp() {
        coordinator.quitApp()
    }
}
