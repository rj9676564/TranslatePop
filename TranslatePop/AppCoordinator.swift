import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var permissionState: PermissionState {
        didSet {
            statusBarController?.updateIcon(name: menuBarIconName)
        }
    }
    @Published var latestStatus = "等待取词"
    @Published var isMonitoring = false

    let settingsStore: SettingsStore
    let permissionService: PermissionService

    var menuBarIconName: String {
        permissionState.accessibilityGranted ? "captions.bubble.fill" : "exclamationmark.bubble.fill"
    }

    private var popupPresenter: PopupPresenter
    private var statusBarController: StatusBarController?
    private var triggerDecisionEngine = TriggerDecisionEngine()
    private var globalMouseDownMonitor: Any?
    private var globalMouseDraggedMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var isLeftMouseDragging = false

    init() {
        let settingsStore = SettingsStore()
        let permissionService = PermissionService()
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.permissionState = permissionService.currentState()
        self.popupPresenter = PopupPresenter()
        self.statusBarController = StatusBarController(coordinator: self)
        startMonitoring()
    }

    deinit {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
        }
        if let globalMouseDraggedMonitor {
            NSEvent.removeMonitor(globalMouseDraggedMonitor)
        }
    }

    func refreshPermissions() {
        permissionState = permissionService.currentState()
        DebugLogger.app.info("刷新权限状态：accessibility=\(self.permissionState.accessibilityGranted, privacy: .public) screenCapture=\(self.permissionState.screenCaptureLikelyGranted, privacy: .public)")
    }

    func requestAccessibilityPermission() {
        permissionService.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func requestScreenCapturePermission() {
        permissionService.requestScreenCapturePermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    func openScreenCaptureSettings() {
        permissionService.openScreenCaptureSettings()
    }

    func saveSettings() {
        settingsStore.save()
        latestStatus = "设置已保存"
    }

    func testTranslationConnection() async {
        settingsStore.save()
        do {
            try await makeTranslationService().testConnection()
            latestStatus = "接口连通成功"
        } catch {
            latestStatus = error.localizedDescription
        }
    }

    func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    func toggleMonitoring() {
        isMonitoring.toggle()
        latestStatus = isMonitoring ? "已恢复监听" : "已暂停监听"
    }

    func triggerManualOCR() {
        Task { @MainActor [weak self] in
            await self?.handleManualOCR()
        }
    }

    private func startMonitoring() {
        isMonitoring = true

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isMonitoring else { return }
            self.isLeftMouseDragging = false
            if event.clickCount >= 2 {
                self.scheduleTrigger(.doubleClick, location: NSEvent.mouseLocation)
            }
        }

        globalMouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self, self.isMonitoring else { return }
            self.isLeftMouseDragging = true
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, self.isMonitoring else { return }
            guard self.isLeftMouseDragging else { return }
            self.isLeftMouseDragging = false
            self.scheduleTrigger(.dragSelection, location: NSEvent.mouseLocation)
        }
    }

    private func scheduleTrigger(_ kind: SelectionTriggerKind, location: CGPoint) {
        DebugLogger.app.info("收到触发事件：kind=\(String(describing: kind), privacy: .public)")
        Task { @MainActor [weak self] in
            let delay: Duration = kind == .doubleClick ? .milliseconds(160) : .milliseconds(220)
            try? await Task.sleep(for: delay)
            await self?.handleTrigger(kind, location: location)
        }
    }

    private func handleTrigger(_ kind: SelectionTriggerKind, location: CGPoint) async {
        refreshPermissions()
        do {
            let selection = try await makeSelectionCaptureService().captureSelection(near: location)
            guard triggerDecisionEngine.shouldAccept(text: selection.text, now: .now) else {
                DebugLogger.app.info("触发被去重过滤")
                return
            }

            let limitedText = String(selection.text.prefix(800))
            let normalizedSelection = CapturedSelection(
                text: limitedText,
                method: selection.method,
                anchorPoint: selection.anchorPoint,
                capturedAt: selection.capturedAt
            )

            popupPresenter.presentLoading(for: normalizedSelection)
            latestStatus = kind == .doubleClick ? "双击取词成功" : "划词取句成功"
            DebugLogger.app.info("捕获文本成功：method=\(normalizedSelection.method.rawValue, privacy: .public) text=\(limitedText, privacy: .public)")

            do {
                let result = try await makeTranslationService().translate(.init(text: limitedText))
                popupPresenter.presentResult(selection: normalizedSelection, result: result)
                latestStatus = "翻译完成"
                DebugLogger.app.info("翻译成功")
            } catch {
                popupPresenter.presentError(
                    message: error.localizedDescription,
                    originalText: limitedText,
                    method: normalizedSelection.method,
                    anchor: normalizedSelection.anchorPoint
                )
                latestStatus = error.localizedDescription
                DebugLogger.app.error("翻译失败：\(error.localizedDescription, privacy: .public)")
            }
        } catch {
            if shouldSuppressAutomaticPopup(for: error) {
                popupPresenter.dismiss()
                latestStatus = "等待取词"
                DebugLogger.app.info("自动触发已静默忽略：\(error.localizedDescription, privacy: .public)")
                return
            }

            popupPresenter.presentError(
                message: error.localizedDescription,
                originalText: nil,
                method: nil,
                anchor: location
            )
            latestStatus = error.localizedDescription
            DebugLogger.app.error("取词失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleManualOCR() async {
        guard settingsStore.ocrEnabled else {
            latestStatus = "请先在设置中启用手动 OCR"
            return
        }

        refreshPermissions()
        let location = NSEvent.mouseLocation

        do {
            let selection = try await OCRSelectionStrategy(recognizer: OCRService()).captureSelection(near: location)
            let limitedText = String(selection.text.prefix(800))
            let normalizedSelection = CapturedSelection(
                text: limitedText,
                method: selection.method,
                anchorPoint: selection.anchorPoint,
                capturedAt: selection.capturedAt
            )

            popupPresenter.presentLoading(for: normalizedSelection)
            latestStatus = "手动 OCR 取词成功"
            DebugLogger.app.info("手动 OCR 成功：text=\(limitedText, privacy: .public)")

            do {
                let result = try await makeTranslationService().translate(.init(text: limitedText))
                popupPresenter.presentResult(selection: normalizedSelection, result: result)
                latestStatus = "翻译完成"
                DebugLogger.app.info("手动 OCR 翻译成功")
            } catch {
                popupPresenter.presentError(
                    message: error.localizedDescription,
                    originalText: limitedText,
                    method: normalizedSelection.method,
                    anchor: normalizedSelection.anchorPoint
                )
                latestStatus = error.localizedDescription
                DebugLogger.app.error("手动 OCR 翻译失败：\(error.localizedDescription, privacy: .public)")
            }
        } catch {
            popupPresenter.presentError(
                message: error.localizedDescription,
                originalText: nil,
                method: .ocr,
                anchor: location
            )
            latestStatus = error.localizedDescription
            DebugLogger.app.error("手动 OCR 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeSelectionCaptureService() -> SelectionCapturing {
        let strategies: [SelectionCaptureStrategy] = [
            AccessibilitySelectionStrategy(permissionService: permissionService),
            ClipboardSelectionStrategy(permissionService: permissionService)
        ]

        return SelectionCaptureService(strategies: strategies)
    }

    private func makeTranslationService() -> Translating {
        TranslationService(configuration: settingsStore.providerConfiguration)
    }

    private func shouldSuppressAutomaticPopup(for error: Error) -> Bool {
        guard let failure = error as? CaptureFailure else {
            return false
        }

        switch failure {
        case .missingAccessibilityPermission,
             .noSupportedSelection,
             .clipboardUnavailable,
             .emptyResult:
            return true
        case .ocrUnavailable:
            return false
        }
    }
}
