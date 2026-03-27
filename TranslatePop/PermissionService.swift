import ApplicationServices
import AppKit
import Foundation

struct PermissionService: Sendable {
    func currentState() -> PermissionState {
        PermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenCaptureLikelyGranted: CGPreflightScreenCaptureAccess()
        )
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
