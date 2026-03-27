import CoreGraphics
import Foundation
import Testing
@testable import TranslatePop

struct TranslatePopTests {

    @Test
    func triggerDecisionEngineBlocksDuplicateAndLongText() {
        var engine = TriggerDecisionEngine(duplicateInterval: 1, maxTextLength: 5)
        let first = engine.shouldAccept(text: "hello", now: Date(timeIntervalSince1970: 10))
        let duplicate = engine.shouldAccept(text: "hello", now: Date(timeIntervalSince1970: 10.2))
        let tooLong = engine.shouldAccept(text: "hello world", now: Date(timeIntervalSince1970: 12))
        #expect(first)
        #expect(!duplicate)
        #expect(!tooLong)
    }

    @Test
    func triggerDecisionEngineReportsRejectionReason() {
        var engine = TriggerDecisionEngine(duplicateInterval: 1, maxTextLength: 5)

        let tooLong = engine.rejectionReason(text: "hello world", now: Date(timeIntervalSince1970: 10))
        let accepted = engine.rejectionReason(text: "hello", now: Date(timeIntervalSince1970: 11))
        let duplicate = engine.rejectionReason(text: "hello", now: Date(timeIntervalSince1970: 11.2))

        #expect(tooLong == .tooLong)
        #expect(accepted == nil)
        #expect(duplicate == .duplicate)
    }

    @Test
    func triggerDecisionEngineBlocksPunctuationOnlySelection() {
        var engine = TriggerDecisionEngine()
        let comma = engine.shouldAccept(text: "，", now: Date(timeIntervalSince1970: 20))
        let punctuation = engine.shouldAccept(text: "...", now: Date(timeIntervalSince1970: 21))
        let chinese = engine.shouldAccept(text: "你好", now: Date(timeIntervalSince1970: 22))
        let english = engine.shouldAccept(text: "hello", now: Date(timeIntervalSince1970: 23))
        let mixed = engine.shouldAccept(text: "OpenAI 中文", now: Date(timeIntervalSince1970: 24))

        #expect(!comma)
        #expect(!punctuation)
        #expect(!chinese)
        #expect(english)
        #expect(mixed)
    }

    @Test
    func translationParserReadsFirstChoice() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "你好，世界"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try TranslationResponseParser.parse(data: json)
        #expect(parsed.text == "你好，世界")
    }

    @Test
    func providerConfigurationDefaultsPathForCompatibleProvider() {
        let configuration = ProviderConfiguration(
            providerName: "OpenAI Compatible",
            providerKind: .openAICompatible,
            baseURL: "https://example.com",
            apiKey: "token",
            model: "gpt-test",
            timeoutSeconds: 20,
            customHeaders: ""
        )

        #expect(configuration.resolvedURL?.absoluteString == "https://example.com/chat/completions")
    }

    @Test
    func providerConfigurationFallsBackToSuggestedModelWhenEmpty() {
        let zhipuConfiguration = ProviderConfiguration(
            providerName: "Zhipu",
            providerKind: .zhipu,
            baseURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            apiKey: "token",
            model: "",
            timeoutSeconds: 20,
            customHeaders: ""
        )

        #expect(zhipuConfiguration.isValid)
        #expect(zhipuConfiguration.effectiveModel == "glm-5")
    }

    @Test
    func popupPositionerKeepsPanelInsideVisibleFrame() {
        let frame = PopupPositioner.frame(
            for: CGPoint(x: 790, y: 20),
            panelSize: CGSize(width: 240, height: 140),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(frame.minX >= 0)
        #expect(frame.maxX <= 800)
        #expect(frame.minY >= 0)
        #expect(frame.maxY <= 600)
    }

    @Test
    func popupPositionerAvoidsAnchorAreaWhenPossible() {
        let anchor = CGPoint(x: 400, y: 300)
        let frame = PopupPositioner.frame(
            for: anchor,
            panelSize: CGSize(width: 240, height: 140),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )

        #expect(abs(frame.minX - anchor.x) >= 52 || abs(frame.maxX - anchor.x) >= 52)
        #expect(abs(frame.minY - anchor.y) >= 40 || abs(frame.maxY - anchor.y) >= 40)
    }

    @Test
    @MainActor
    func selectionCaptureServiceFallsBackToLaterStrategies() async throws {
        let service = SelectionCaptureService(strategies: [
            MockCaptureStrategy(error: CaptureFailure.noSupportedSelection),
            MockCaptureStrategy(result: CapturedSelection(
                text: "selected text",
                method: .clipboard,
                anchorPoint: CGPoint(x: 10, y: 10),
                capturedAt: .now
            ))
        ])

        let selection = try await service.captureSelection(near: CGPoint(x: 0, y: 0))
        #expect(selection.method == .clipboard)
        #expect(selection.text == "selected text")
    }
}

private struct MockCaptureStrategy: SelectionCaptureStrategy {
    let method: CaptureMethod
    let result: CapturedSelection?
    let error: Error?

    init(result: CapturedSelection) {
        self.method = result.method
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.method = .accessibility
        self.result = nil
        self.error = error
    }

    func captureSelection(near point: CGPoint) async throws -> CapturedSelection {
        if let error {
            throw error
        }
        return result!
    }
}
