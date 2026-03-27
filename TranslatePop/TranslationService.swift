import Foundation

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

    func testConnection() async throws {
        _ = try await translate(.init(text: "hello world"))
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
}

struct TranslationResponseParser {
    static func parse(data: Data) throws -> ParsedTranslation {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let text = response.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw TranslationFailure.emptyTranslation
        }
        return ParsedTranslation(text: text)
    }
}

struct ParsedTranslation: Equatable {
    let text: String
}

private extension TranslationProviderAdapting {
    func performChatCompletion(
        request: TranslationRequest,
        configuration: ProviderConfiguration,
        session: URLSession
    ) async throws -> TranslationResult {
        guard let url = configuration.resolvedURL else {
            throw TranslationFailure.invalidConfiguration
        }

        let payload = ChatCompletionRequest(
            model: configuration.effectiveModel,
            messages: [
                .init(role: "system", content: request.systemPrompt),
                .init(role: "user", content: request.text)
            ],
            stream: false,
            temperature: 0.2
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw TranslationFailure.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationFailure.invalidResponse
        }
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
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double
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
