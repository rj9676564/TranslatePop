import AppKit
import Foundation

protocol SelectionCapturing: Sendable {
    func captureSelection(near point: CGPoint) async throws -> CapturedSelection
}

protocol SelectionCaptureStrategy: Sendable {
    var method: CaptureMethod { get }
    func captureSelection(near point: CGPoint) async throws -> CapturedSelection
}

protocol Translating: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationStreamUpdate, Error>
    func testConnection(promptConfiguration: PromptConfiguration) async throws
}

protocol TranslationProviderAdapting: Sendable {
    var kind: TranslationProviderKind { get }
    func translate(_ request: TranslationRequest, configuration: ProviderConfiguration) async throws -> TranslationResult
    func translateStream(
        _ request: TranslationRequest,
        configuration: ProviderConfiguration
    ) -> AsyncThrowingStream<TranslationStreamUpdate, Error>
}

protocol OCRRecognizing: Sendable {
    func recognizeText(near point: CGPoint) async throws -> String
}

@MainActor
protocol PopupPresenting: AnyObject {
    func presentPending(at anchor: CGPoint)
    func presentLoading(for selection: CapturedSelection)
    func presentStreaming(selection: CapturedSelection, partialText: String, providerName: String)
    func presentResult(selection: CapturedSelection, result: TranslationResult)
    func presentError(message: String, originalText: String?, method: CaptureMethod?, anchor: CGPoint)
    func dismiss()
}
