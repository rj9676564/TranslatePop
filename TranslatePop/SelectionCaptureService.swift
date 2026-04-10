import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import Vision

actor SelectionCaptureService: SelectionCapturing {
    private let strategies: [SelectionCaptureStrategy]

    init(strategies: [SelectionCaptureStrategy]) {
        self.strategies = strategies
    }

    func captureSelection(near point: CGPoint) async throws -> CapturedSelection {
        var firstError: Error?
        for strategy in strategies {
            do {
                let selection = try await strategy.captureSelection(near: point)
                let normalized = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw CaptureFailure.emptyResult
                }
                return CapturedSelection(
                    text: normalized,
                    method: selection.method,
                    anchorPoint: selection.anchorPoint,
                    capturedAt: selection.capturedAt
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        throw firstError ?? CaptureFailure.noSupportedSelection
    }
}

struct AccessibilitySelectionStrategy: SelectionCaptureStrategy {
    let method: CaptureMethod = .accessibility
    private let permissionService: PermissionService

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    func captureSelection(near point: CGPoint) async throws -> CapturedSelection {
        guard permissionService.currentState().accessibilityGranted else {
            throw CaptureFailure.missingAccessibilityPermission
        }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard status == .success, let focused = focusedValue else {
            throw CaptureFailure.noSupportedSelection
        }

        let focusedElement = focused as! AXUIElement
        if let text = copyString(attribute: kAXSelectedTextAttribute as CFString, from: focusedElement) {
            return CapturedSelection(text: text, method: method, anchorPoint: point, capturedAt: .now)
        }

        if let text = copyString(attribute: kAXValueAttribute as CFString, from: focusedElement),
           let rawRangeValue = copyValue(attribute: kAXSelectedTextRangeAttribute as CFString, from: focusedElement),
           CFGetTypeID(rawRangeValue) == AXValueGetTypeID() {
            let rangeValue = rawRangeValue as! AXValue
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 {
                let nsRange = NSRange(location: range.location, length: range.length)
                let nsText = text as NSString
                if NSMaxRange(nsRange) <= nsText.length {
                    return CapturedSelection(
                        text: nsText.substring(with: nsRange),
                        method: method,
                        anchorPoint: point,
                        capturedAt: .now
                    )
                }
            }
        }

        throw CaptureFailure.noSupportedSelection
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        copyValue(attribute: attribute, from: element) as? String
    }

    private func copyValue(attribute: CFString, from element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value
    }
}

struct ClipboardSelectionStrategy: SelectionCaptureStrategy {
    let method: CaptureMethod = .clipboard
    private let permissionService: PermissionService
    private let userDidManualCopy: Bool

    init(permissionService: PermissionService, userDidManualCopy: Bool) {
        self.permissionService = permissionService
        self.userDidManualCopy = userDidManualCopy
    }

    func captureSelection(near point: CGPoint) async throws -> CapturedSelection {
        guard permissionService.currentState().accessibilityGranted else {
            throw CaptureFailure.clipboardUnavailable
        }

        let pasteboard = NSPasteboard.general
        if userDidManualCopy,
           let copied = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !copied.isEmpty {
            return CapturedSelection(text: copied, method: method, anchorPoint: point, capturedAt: .now)
        }
        let originalItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { partial, type in
                partial[type] = item.data(forType: type)
            }
        } ?? []
        let originalChangeCount = pasteboard.changeCount

        try simulateCopyShortcut()

        try await Task.sleep(for: .milliseconds(180))
        
        // 如果在等待期间任务被取消（例如用户手动触发了复制），则不再执行后续逻辑，更不能恢复旧剪贴板
        if Task.isCancelled {
            throw CancellationError()
        }

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != originalChangeCount,
              let copied = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !copied.isEmpty else {
            restorePasteboard(originalItems)
            throw CaptureFailure.clipboardUnavailable
        }

        // 核心竞争保护逻辑：
        // 如果 changeCount 正好只增加了 1（即只有模拟复制这一步），我们执行恢复逻辑。
        // 如果增加了超过 1，说明在此期间用户很大率也执行了手动复制，此时跳过恢复以保护用户内容。
        if currentChangeCount == originalChangeCount + 1 {
            restorePasteboard(originalItems)
        }
        
        return CapturedSelection(text: copied, method: method, anchorPoint: point, capturedAt: .now)
    }

    private func simulateCopyShortcut() throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            throw CaptureFailure.clipboardUnavailable
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        snapshot.forEach { itemData in
            let item = NSPasteboardItem()
            itemData.forEach { type, data in
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }
}

struct OCRSelectionStrategy: SelectionCaptureStrategy {
    let method: CaptureMethod = .ocr
    private let recognizer: OCRRecognizing

    init(recognizer: OCRRecognizing) {
        self.recognizer = recognizer
    }

    func captureSelection(near point: CGPoint) async throws -> CapturedSelection {
        let text = try await recognizer.recognizeText(near: point)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CaptureFailure.ocrUnavailable
        }
        return CapturedSelection(text: normalized, method: method, anchorPoint: point, capturedAt: .now)
    }
}

actor OCRService: OCRRecognizing {
    func recognizeText(near point: CGPoint) async throws -> String {
        let captureRect = CGRect(x: point.x - 220, y: point.y - 90, width: 440, height: 180)
        let shareableContent = try await SCShareableContent.current
        guard let display = shareableContent.displays.first(where: { $0.frame.contains(point) }) ?? shareableContent.displays.first else {
            throw CaptureFailure.ocrUnavailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(captureRect.width)
        configuration.height = Int(captureRect.height)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureFailure.ocrUnavailable
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            let strings = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.isEmpty } ?? []
            guard !strings.isEmpty else {
                throw CaptureFailure.ocrUnavailable
            }
            return strings.joined(separator: " ")
        } catch {
            throw CaptureFailure.ocrUnavailable
        }
    }
}
