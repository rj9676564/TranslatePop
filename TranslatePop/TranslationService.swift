import Foundation
import OSLog

struct TranslationService: Translating {
    private let configuration: ProviderConfiguration
    private let adapters: [any TranslationProviderAdapting]

    init(
        configuration: ProviderConfiguration,
        adapters: [any TranslationProviderAdapting] = [
            OpenAICompatibleTranslationAdapter(),
            ZhipuTranslationAdapter()
        ]
    ) {
        self.configuration = configuration
        self.adapters = adapters
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard configuration.isValid else {
            throw TranslationFailure.invalidConfiguration
        }

        guard let adapter = adapters.first(where: { $0.kind == configuration.providerKind }) else {
            throw TranslationFailure.invalidConfiguration
        }

        return try await adapter.translate(request, configuration: configuration)
    }

    func translateStream(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationStreamUpdate, Error> {
        guard configuration.isValid else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TranslationFailure.invalidConfiguration)
            }
        }

        guard let adapter = adapters.first(where: { $0.kind == configuration.providerKind }) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TranslationFailure.invalidConfiguration)
            }
        }

        return adapter.translateStream(request, configuration: configuration)
    }

    func testConnection(promptConfiguration: PromptConfiguration) async throws {
        _ = try await translate(.init(text: "hello world", promptConfiguration: promptConfiguration))
    }
}

struct OpenAICompatibleTranslationAdapter: TranslationProviderAdapting {
    let kind: TranslationProviderKind = .openAICompatible
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translate(_ request: TranslationRequest, configuration: ProviderConfiguration) async throws -> TranslationResult {
        try await performChatCompletion(
            request: request,
            configuration: configuration,
            session: session
        )
    }

    func translateStream(
        _ request: TranslationRequest,
        configuration: ProviderConfiguration
    ) -> AsyncThrowingStream<TranslationStreamUpdate, Error> {
        performStreamingChatCompletion(
            request: request,
            configuration: configuration,
            session: session
        )
    }
}

struct ZhipuTranslationAdapter: TranslationProviderAdapting {
    let kind: TranslationProviderKind = .zhipu
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translate(_ request: TranslationRequest, configuration: ProviderConfiguration) async throws -> TranslationResult {
        try await performChatCompletion(
            request: request,
            configuration: configuration,
            session: session
        )
    }

    func translateStream(
        _ request: TranslationRequest,
        configuration: ProviderConfiguration
    ) -> AsyncThrowingStream<TranslationStreamUpdate, Error> {
        performStreamingChatCompletion(
            request: request,
            configuration: configuration,
            session: session
        )
    }
}

struct TranslationResponseParser {
    static func parse(data: Data) throws -> ParsedTranslation {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let rawText = response.choices.first?.message.content ?? ""
        let cleanedText = cleanResponse(rawText)
        guard !cleanedText.isEmpty else {
            throw TranslationFailure.emptyTranslation
        }
        return ParsedTranslation(text: cleanedText)
    }

    static func cleanResponse(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 移除 ```markdown ... ``` 这种包装
        if cleaned.hasPrefix("```markdown") {
            cleaned = String(cleaned.dropFirst(11))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        
        // 有些 AI 会在开头直接写 "markdown\n" 而没有反引号，也要删掉
        if cleaned.lowercased().hasPrefix("markdown\n") {
            cleaned = String(cleaned.dropFirst(9))
        } else if cleaned.lowercased().hasPrefix("markdown ") {
            cleaned = String(cleaned.dropFirst(9))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ParsedTranslation: Equatable {
    let text: String
}

private extension TranslationProviderAdapting {
    func makeURLRequest(
        request: TranslationRequest,
        configuration: ProviderConfiguration,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = configuration.resolvedURL else {
            throw TranslationFailure.invalidConfiguration
        }

        let payload = ChatCompletionRequest(
            model: configuration.effectiveModel,
            messages: [
                .init(role: "system", content: request.systemPrompt),
                .init(role: "user", content: request.text)
            ],
            stream: stream,
            temperature: 0.2,
            enableThinking: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        configuration.parsedHeaders.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        logRequest(urlRequest, configuration: configuration, stream: stream)
        return urlRequest
    }

    func performChatCompletion(
        request: TranslationRequest,
        configuration: ProviderConfiguration,
        session: URLSession
    ) async throws -> TranslationResult {
        let urlRequest = try makeURLRequest(
            request: request,
            configuration: configuration,
            stream: false
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw TranslationFailure.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationFailure.invalidResponse
        }
        logResponse(httpResponse, data: data, stream: false)
        if httpResponse.statusCode == 401 {
            throw TranslationFailure.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "status=\(httpResponse.statusCode)"
            throw TranslationFailure.network(message)
        }

        let decoded = try TranslationResponseParser.parse(data: data)
        return TranslationResult(
            originalText: request.text,
            translatedText: decoded.text,
            detectedSourceLanguage: request.sourceLanguage,
            providerName: configuration.providerName
        )
    }

    func performStreamingChatCompletion(
        request: TranslationRequest,
        configuration: ProviderConfiguration,
        session: URLSession
    ) -> AsyncThrowingStream<TranslationStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(
                        request: request,
                        configuration: configuration,
                        stream: true
                    )

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TranslationFailure.invalidResponse
                    }
                    logStreamingResponse(httpResponse)
                    if httpResponse.statusCode == 401 {
                        throw TranslationFailure.unauthorized
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let data = try await collectData(from: bytes)
                        logResponse(httpResponse, data: data, stream: true)
                        let message = String(data: data, encoding: .utf8) ?? "status=\(httpResponse.statusCode)"
                        throw TranslationFailure.network(message)
                    }

                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if !contentType.localizedCaseInsensitiveContains("text/event-stream") {
                        let data = try await collectData(from: bytes)
                        logResponse(httpResponse, data: data, stream: true)
                        let decoded = try TranslationResponseParser.parse(data: data)
                        continuation.yield(.init(text: decoded.text, providerName: configuration.providerName))
                        continuation.finish()
                        return
                    }

                    var accumulatedText = ""
                    var chunkCount = 0
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { return }
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmedLine.hasPrefix("data:") else { continue }
                        let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try StreamingTranslationResponseParser.parse(data: data),
                           !chunk.isEmpty {
                            chunkCount += 1
                            if chunkCount <= 3 || chunkCount % 20 == 0 {
                                DebugLogger.network.info(
                                    "HTTP 流式 chunk：index=\(chunkCount, privacy: .public) length=\(chunk.count, privacy: .public) preview=\(self.preview(chunk), privacy: .public)"
                                )
                            }
                            accumulatedText += chunk
                            continuation.yield(.init(text: accumulatedText, providerName: configuration.providerName))
                        }
                    }

                    let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    DebugLogger.network.info(
                        "HTTP 流式完成：chunks=\(chunkCount, privacy: .public) finalLength=\(finalText.count, privacy: .public)"
                    )
                    guard !finalText.isEmpty else {
                        throw TranslationFailure.emptyTranslation
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    func logRequest(_ request: URLRequest, configuration: ProviderConfiguration, stream: Bool) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        let timeout = Int(request.timeoutInterval)
        let headers = sanitizedHeaders(from: request)
        let bodyPreview = preview(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")

        DebugLogger.network.info(
            "HTTP 请求：method=\(method, privacy: .public) url=\(url, privacy: .public) provider=\(configuration.providerName, privacy: .public) model=\(configuration.effectiveModel, privacy: .public) stream=\(stream, privacy: .public) timeout=\(timeout, privacy: .public)s headers=\(headers, privacy: .public) body=\(bodyPreview, privacy: .public)"
        )
    }

    func logResponse(_ response: HTTPURLResponse, data: Data, stream: Bool) {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let bodyPreview = preview(String(data: data, encoding: .utf8) ?? "")
        DebugLogger.network.info(
            "HTTP 响应：status=\(response.statusCode, privacy: .public) stream=\(stream, privacy: .public) contentType=\(contentType, privacy: .public) body=\(bodyPreview, privacy: .public)"
        )
    }

    func logStreamingResponse(_ response: HTTPURLResponse) {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        DebugLogger.network.info(
            "HTTP 流式响应头：status=\(response.statusCode, privacy: .public) contentType=\(contentType, privacy: .public)"
        )
    }

    func sanitizedHeaders(from request: URLRequest) -> String {
        let headers = request.allHTTPHeaderFields ?? [:]
        if headers.isEmpty { return "{}" }
        let pairs = headers
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                    return "\(key): Bearer ***"
                }
                return "\(key): \(value)"
            }
        return "{\(pairs.joined(separator: ", "))}"
    }

    func preview(_ text: String, limit: Int = 280) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }
}

private struct ChatCompletionRequest: Encodable {
    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case enableThinking = "enable_thinking"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double
    let enableThinking: Bool?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private enum StreamingTranslationResponseParser {
    static func parse(data: Data) throws -> String? {
        let response = try JSONDecoder().decode(ChatCompletionStreamResponse.self, from: data)
        return response.choices
            .compactMap { $0.delta.content }
            .joined()
    }
}

private struct ChatCompletionStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}
