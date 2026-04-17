import AppKit
import Foundation
import SwiftData

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
    var promptConfiguration: PromptConfiguration = .default

    var normalizedLookupText: String {
        LookupTextNormalizer.normalize(text)
    }
    
    var systemPrompt: String {
        promptConfiguration.systemPrompt(for: text)
    }
}

struct PromptConfiguration: Equatable, Codable, Sendable {
    static let defaultWordPrompt = """
    你是一位专业的词典与词源学专家。

    请针对给定单词，严格按照以下结构输出内容：

    ---

    1. **Result**
    - 直接给出该单词的中文核心释义（使用**加粗**）。
    - 保持简洁、准确，不要添加多余解释。

    ---

    2. **词源解析（Etymology）**
    - 说明该词的来源语言（如拉丁语、希腊语、古英语等）及其演变过程。
    - 如果是**复合词**（如 however、into），请说明各部分单词如何组合形成该词。
      → 此情况下必须跳过“词形结构”部分。
    - 如果是**派生词**（含真实前缀/后缀），请说明词根的核心含义。

    ---

    3. **词形结构**（仅在派生词时输出）
    - 前缀（Prefix）：（仅当属于标准语言学前缀时才输出）
    - 词根（Root）：
    - 后缀（Suffix）：（仅当属于标准语言学后缀时才输出）

    ---

    4. **常用搭配（Collocations）**
    - 列出 2–3 个常见英文搭配
    - 每个搭配需附带简洁中文释义

    ---

    【严格规则（必须遵守）】
    - 不得虚构前缀或后缀
    - 不得将复合词的组成部分误标为前缀或后缀
    - 不得输出空内容或占位词（如“无 / 没有 / None”）
    - 所有解释必须使用简体中文
    - 输出必须结构清晰、格式统一
    - 内容保持专业、简洁
    """

    static let defaultSentencePrompt = "You are a translation engine. Detect the source language automatically and translate the user text into concise Simplified Chinese. Return translation only."

    static let `default` = PromptConfiguration()

    var wordPrompt: String = PromptConfiguration.defaultWordPrompt
    var sentencePrompt: String = PromptConfiguration.defaultSentencePrompt

    func systemPrompt(for text: String) -> String {
        if LookupTextNormalizer.isSingleEnglishWord(text) {
            return wordPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sentencePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LookupTextNormalizer {
    private static let singleEnglishWordPattern = #"^[A-Za-z]+(?:['’-][A-Za-z]+)*$"#

    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSingleEnglishWord(trimmed) else {
            return trimmed
        }
        return trimmed.lowercased()
    }

    static func isSingleEnglishWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.range(
            of: singleEnglishWordPattern,
            options: .regularExpression
        ) != nil
    }
}

struct TranslationResult: Equatable, Sendable, Codable {
    let originalText: String
    let translatedText: String
    let detectedSourceLanguage: String?
    let providerName: String
}

@Model
final class TranslationHistoryItem {
    @Attribute(.unique) var normalizedText: String
    var originalText: String
    var translatedText: String
    var providerName: String
    var createdAt: Date
    
    // 预留字段：方便以后做“生词本”或“星标”功能
    var isFavorite: Bool = false
    var lookupCount: Int = 1

    init(result: TranslationResult) {
        self.normalizedText = LookupTextNormalizer.normalize(result.originalText)
        self.originalText = result.originalText
        self.translatedText = result.translatedText
        self.providerName = result.providerName
        self.createdAt = Date()
    }
}

struct TranslationStreamUpdate: Equatable, Sendable {
    let text: String
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
    case streaming(selection: CapturedSelection, partialText: String, providerName: String)
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

enum TriggerMode: String, Codable, CaseIterable, Sendable {
    case automatic = "自动（划词或双击）"
    case modifierKey = "按住 Option 键"
    case manualOnly = "手动（点击图标或快捷键）"
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
