import AppKit
import Foundation

enum CaptureMethod: String, Codable, CaseIterable, Sendable {
    case accessibility = "辅助功能"
    case clipboard = "剪贴板回退"
    case ocr = "OCR"
}

struct CapturedSelection: Equatable, Sendable {
    let text: String
    let method: CaptureMethod
    let anchorPoint: CGPoint
    let capturedAt: Date
}

struct TranslationRequest: Equatable, Sendable {
    var text: String
    var sourceLanguage: String?
    var targetLanguage: String = "zh-Hans"
    var systemPrompt: String = "You are a translation engine. Detect the source language automatically and translate the user text into concise Simplified Chinese. Return translation only."
}

struct TranslationResult: Equatable, Sendable {
    let originalText: String
    let translatedText: String
    let detectedSourceLanguage: String?
    let providerName: String
}

struct ProviderConfiguration: Equatable, Codable, Sendable {
    var providerName: String = "OpenAI Compatible"
    var providerKind: TranslationProviderKind = .openAICompatible
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
    var timeoutSeconds: Double = 20
    var customHeaders: String = ""

    var isValid: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var missingFieldLabels: [String] {
        var fields: [String] = []
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("Base URL")
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("API Key")
        }
        return fields
    }

    var effectiveModel: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            return trimmedModel
        }

        switch providerKind {
        case .openAICompatible:
            return "gpt-4.1-mini"
        case .zhipu:
            return "glm-5"
        }
    }

    var resolvedURL: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        if url.path.isEmpty || url.path == "/" {
            return url.appending(path: "chat/completions")
        }

        return url
    }

    var parsedHeaders: [String: String] {
        var headers: [String: String] = [:]
        for line in customHeaders.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    mutating func applySuggestedTemplate(for kind: TranslationProviderKind) {
        providerKind = kind

        switch kind {
        case .openAICompatible:
            if providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerName == "Zhipu" {
                providerName = "OpenAI Compatible"
            }
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL == "https://open.bigmodel.cn/api/paas/v4/chat/completions" {
                baseURL = "https://api.openai.com/v1"
            }
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == "glm-5" {
                model = "gpt-4.1-mini"
            }
        case .zhipu:
            if providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerName == "OpenAI Compatible" {
                providerName = "Zhipu"
            }
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL == "https://api.openai.com/v1" {
                baseURL = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
            }
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == "gpt-4.1-mini" {
                model = "glm-5"
            }
        }
    }
}

enum TranslationProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompatible = "OpenAI Compatible"
    case zhipu = "Zhipu"
}

struct PermissionState: Equatable, Sendable {
    var accessibilityGranted = false
    var screenCaptureLikelyGranted = false

    var summaryText: String {
        if accessibilityGranted && screenCaptureLikelyGranted {
            return "辅助功能和手动 OCR 权限已就绪"
        }
        if accessibilityGranted {
            return "已可自动取词；如需手动 OCR，请再开启屏幕录制权限"
        }
        return "需要开启辅助功能权限后才能在其他软件里取词"
    }
}

enum PopupContentState: Equatable, Sendable {
    case idle
    case pending
    case loading(originalText: String, method: CaptureMethod)
    case result(CapturedSelection, TranslationResult)
    case error(message: String, originalText: String?, method: CaptureMethod?)
}

enum CaptureFailure: LocalizedError, Equatable, Sendable {
    case missingAccessibilityPermission
    case noSupportedSelection
    case clipboardUnavailable
    case ocrUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingAccessibilityPermission:
            return "缺少辅助功能权限"
        case .noSupportedSelection:
            return "当前软件没有暴露可读的选中文本"
        case .clipboardUnavailable:
            return "剪贴板回退失败"
        case .ocrUnavailable:
            return "OCR 识别失败"
        case .emptyResult:
            return "没有捕获到有效文本"
        }
    }
}

enum TranslationFailure: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case unauthorized
    case emptyTranslation
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "翻译接口配置不完整，请填写 Base URL 和 API Key"
        case .invalidResponse:
            return "翻译接口返回格式无法解析"
        case .unauthorized:
            return "翻译接口鉴权失败，请检查 API Key"
        case .emptyTranslation:
            return "翻译结果为空"
        case .network(let message):
            return "网络请求失败：\(message)"
        }
    }
}

enum SelectionTriggerKind: Sendable {
    case doubleClick
    case dragSelection
}

enum TriggerRejectionReason: Equatable, Sendable {
    case empty
    case tooLong
    case noMeaningfulContent
    case insufficientEnglishRatio
    case duplicate

    var logDescription: String {
        switch self {
        case .empty:
            return "empty"
        case .tooLong:
            return "too_long"
        case .noMeaningfulContent:
            return "no_meaningful_content"
        case .insufficientEnglishRatio:
            return "insufficient_english_ratio"
        case .duplicate:
            return "duplicate"
        }
    }
}

struct TriggerDecisionEngine {
    var duplicateInterval: TimeInterval = 1.2
    var maxTextLength = 3000
    var minimumEnglishRatio = 0.35

    private(set) var lastAcceptedText = ""
    private(set) var lastAcceptedAt = Date.distantPast

    mutating func shouldAccept(text: String, now: Date) -> Bool {
        rejectionReason(text: text, now: now) == nil
    }

    mutating func rejectionReason(text: String, now: Date) -> TriggerRejectionReason? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return .empty }
        guard normalized.count <= maxTextLength else { return .tooLong }
        guard normalized.containsMeaningfulContent else { return .noMeaningfulContent }
        guard normalized.englishLetterRatio >= minimumEnglishRatio else { return .insufficientEnglishRatio }

        if normalized == lastAcceptedText && now.timeIntervalSince(lastAcceptedAt) < duplicateInterval {
            return .duplicate
        }

        lastAcceptedText = normalized
        lastAcceptedAt = now
        return nil
    }
}

private extension String {
    var containsMeaningfulContent: Bool {
        unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            CharacterSet.letters.contains(scalar) ||
            scalar.properties.isEmoji
        }
    }

    var englishLetterRatio: Double {
        let letterScalars = unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
        }

        guard !letterScalars.isEmpty else {
            return 0
        }

        let englishCount = letterScalars.reduce(into: 0) { count, scalar in
            if ("A"..."Z").contains(String(scalar)) || ("a"..."z").contains(String(scalar)) {
                count += 1
            }
        }

        return Double(englishCount) / Double(letterScalars.count)
    }
}

struct PopupPositioner {
    static func frame(
        for anchor: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGRect {
        let offsetX: CGFloat = 52
        let offsetY: CGFloat = 40
        let candidates = [
            CGPoint(x: anchor.x + offsetX, y: anchor.y - panelSize.height - offsetY),
            CGPoint(x: anchor.x + offsetX, y: anchor.y + offsetY),
            CGPoint(x: anchor.x - panelSize.width - offsetX, y: anchor.y - panelSize.height - offsetY),
            CGPoint(x: anchor.x - panelSize.width - offsetX, y: anchor.y + offsetY)
        ]

        let clampedCandidates = candidates.map { candidate in
            CGPoint(
                x: min(
                    max(candidate.x, visibleFrame.minX + margin),
                    visibleFrame.maxX - panelSize.width - margin
                ),
                y: min(
                    max(candidate.y, visibleFrame.minY + margin),
                    visibleFrame.maxY - panelSize.height - margin
                )
            )
        }

        let bestOrigin = clampedCandidates.max { lhs, rhs in
            overlapScore(origin: lhs, anchor: anchor, panelSize: panelSize) <
            overlapScore(origin: rhs, anchor: anchor, panelSize: panelSize)
        } ?? CGPoint(
            x: visibleFrame.minX + margin,
            y: visibleFrame.maxY - panelSize.height - margin
        )

        return CGRect(origin: bestOrigin, size: panelSize)
    }

    private static func overlapScore(origin: CGPoint, anchor: CGPoint, panelSize: CGSize) -> CGFloat {
        let frame = CGRect(origin: origin, size: panelSize)
        let avoidanceRect = CGRect(x: anchor.x - 80, y: anchor.y - 60, width: 160, height: 120)
        let overlap = frame.intersection(avoidanceRect)
        let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
        let distance = hypot(frame.midX - anchor.x, frame.midY - anchor.y)
        return distance - overlapArea * 0.05
    }
}
