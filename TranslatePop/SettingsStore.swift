import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var providerConfiguration: ProviderConfiguration
    @Published var triggerMode: TriggerMode
    @Published var ocrEnabled: Bool
    @Published var minimumEnglishRatio: Double

    private let defaults: UserDefaults
    private let service = "top.mrlb.TranslatePop"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedProviderName = defaults.string(forKey: "providerName") ?? "OpenAI Compatible"
        let storedProviderKind = TranslationProviderKind(rawValue: defaults.string(forKey: "providerKind") ?? "") ?? .openAICompatible
        let storedBaseURL = defaults.string(forKey: "baseURL") ?? ""
        let storedModel = defaults.string(forKey: "model") ?? ""
        let storedHeaders = defaults.string(forKey: "customHeaders") ?? ""
        let storedTimeout = defaults.object(forKey: "timeoutSeconds") as? Double ?? 20
        let storedEnglishRatio = defaults.object(forKey: "minimumEnglishRatio") as? Double ?? 0.35
        let storedApiKey = KeychainHelper.read(service: service, account: "apiKey")
        self.providerConfiguration = ProviderConfiguration(
            providerName: storedProviderName,
            providerKind: storedProviderKind,
            baseURL: storedBaseURL,
            apiKey: storedApiKey,
            model: storedModel,
            timeoutSeconds: storedTimeout,
            customHeaders: storedHeaders
        )
        let storedTriggerMode = TriggerMode(rawValue: defaults.string(forKey: "triggerMode") ?? "") ?? .automatic
        self.triggerMode = storedTriggerMode
        self.ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
        self.minimumEnglishRatio = storedEnglishRatio
    }

    func save() {
        defaults.set(providerConfiguration.providerName, forKey: "providerName")
        defaults.set(providerConfiguration.providerKind.rawValue, forKey: "providerKind")
        defaults.set(providerConfiguration.baseURL, forKey: "baseURL")
        defaults.set(providerConfiguration.model, forKey: "model")
        defaults.set(providerConfiguration.timeoutSeconds, forKey: "timeoutSeconds")
        defaults.set(providerConfiguration.customHeaders, forKey: "customHeaders")
        defaults.set(triggerMode.rawValue, forKey: "triggerMode")
        defaults.set(ocrEnabled, forKey: "ocrEnabled")
        defaults.set(minimumEnglishRatio, forKey: "minimumEnglishRatio")
        KeychainHelper.save(service: service, account: "apiKey", value: providerConfiguration.apiKey)
    }
}
