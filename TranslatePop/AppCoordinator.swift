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
    private var activeTranslationTask: Task<Void, Never>?
    private var globalMouseDownMonitor: Any?
    private var globalSecondaryMouseDownMonitor: Any?
    private var globalMouseDraggedMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var isLeftMouseDragging = false
    private var mouseDownTime: Date = .distantPast
    private var lastManualCopyTime: Date = .distantPast

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
        if let globalSecondaryMouseDownMonitor {
            NSEvent.removeMonitor(globalSecondaryMouseDownMonitor)
        }
        if let globalMouseDraggedMonitor {
            NSEvent.removeMonitor(globalMouseDraggedMonitor)
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
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
        activeTranslationTask?.cancel()
        activeTranslationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.handleManualOCR()
        }
    }

    private func startMonitoring() {
        isMonitoring = true

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isMonitoring else { return }
            self.activeTranslationTask?.cancel()
            self.mouseDownTime = Date()
            self.popupPresenter.dismissForUserInteraction(at: NSEvent.mouseLocation)
            self.isLeftMouseDragging = false
            if event.clickCount >= 2 {
                self.scheduleTrigger(.doubleClick, location: NSEvent.mouseLocation)
            }
        }

        globalSecondaryMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.isMonitoring else { return }
            self.activeTranslationTask?.cancel()
            self.popupPresenter.dismissForUserInteraction(at: NSEvent.mouseLocation)
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isMonitoring else { return }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            
            // 处理复制、剪切、粘贴快捷键
            if event.modifierFlags.contains(.command), (chars == "c" || chars == "x" || chars == "v") {
                if chars == "c" || chars == "x" {
                    self.lastManualCopyTime = Date()
                }

                // 当悬浮窗显示且鼠标不在其范围内时，用户触发复制/粘贴通常意味着当前翻译流已不再被需要
                if self.popupPresenter.isVisible, !self.popupPresenter.isMouseInside(at: NSEvent.mouseLocation) {
                    self.popupPresenter.dismiss()
                    DebugLogger.app.info("用户在外部触发剪贴板操作，自动关闭弹窗")
                }
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
        activeTranslationTask?.cancel()
        activeTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // 根据触发模式判断是否静默
            switch self.settingsStore.triggerMode {
            case .modifierKey:
                // 仅在按住 Option 键时触发
                if !NSEvent.modifierFlags.contains(.option) {
                    return
                }
            case .manualOnly:
                // 不会自动触发
                return
            case .automatic:
                break
            }

            let delay: Duration = kind == .doubleClick ? .milliseconds(160) : .milliseconds(220)
            do {
                try await Task.sleep(for: delay)
                await self.handleTrigger(kind, location: location)
            } catch {
                return
            }
        }
    }

    private func handleTrigger(_ kind: SelectionTriggerKind, location: CGPoint) async {
        refreshPermissions()
        popupPresenter.presentPending(at: location)
        do {
            let selection = try await makeSelectionCaptureService().captureSelection(near: location)
            triggerDecisionEngine.minimumEnglishRatio = settingsStore.minimumEnglishRatio
            let limitedText = String(selection.text.prefix(triggerDecisionEngine.maxTextLength))
            if selection.text.count > triggerDecisionEngine.maxTextLength {
                DebugLogger.app.info("捕获文本超长，已截断为\(self.triggerDecisionEngine.maxTextLength, privacy: .public)字符")
            }

            if let rejectionReason = triggerDecisionEngine.rejectionReason(text: limitedText, now: .now) {
                popupPresenter.dismiss()
                latestStatus = "等待取词"
                DebugLogger.app.info("触发被过滤：reason=\(rejectionReason.logDescription, privacy: .public)")
                return
            }

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
                let result = try await consumeTranslationStream(for: normalizedSelection)
                guard !Task.isCancelled else { return }
                popupPresenter.presentResult(selection: normalizedSelection, result: result)
                latestStatus = "翻译完成"
                DebugLogger.app.info("翻译成功")
            } catch {
                guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
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
        popupPresenter.presentPending(at: location)

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
                let result = try await consumeTranslationStream(for: normalizedSelection)
                guard !Task.isCancelled else { return }
                popupPresenter.presentResult(selection: normalizedSelection, result: result)
                latestStatus = "翻译完成"
                DebugLogger.app.info("手动 OCR 翻译成功")
            } catch {
                guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
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
            ClipboardSelectionStrategy(permissionService: permissionService, userDidManualCopy: self.lastManualCopyTime > self.mouseDownTime)
        ]

        return SelectionCaptureService(strategies: strategies)
    }

    private func makeTranslationService() -> Translating {
        TranslationService(configuration: settingsStore.providerConfiguration)
    }

    private func consumeTranslationStream(for selection: CapturedSelection) async throws -> TranslationResult {
        let service = makeTranslationService()
        var latestPartialText = ""
        var providerName = settingsStore.providerConfiguration.providerName

        for try await update in service.translateStream(.init(text: selection.text)) {
            latestPartialText = update.text
            providerName = update.providerName
            popupPresenter.presentStreaming(
                selection: selection,
                partialText: update.text,
                providerName: update.providerName
            )
        }

        let finalText = latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            throw TranslationFailure.emptyTranslation
        }

        return TranslationResult(
            originalText: selection.text,
            translatedText: finalText,
            detectedSourceLanguage: nil,
            providerName: providerName
        )
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
