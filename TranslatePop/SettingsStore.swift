import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var providerConfiguration: ProviderConfiguration
    @Published var ocrEnabled: Bool

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
        self.ocrEnabled = defaults.object(forKey: "ocrEnabled") as? Bool ?? true
    }

    func save() {
        defaults.set(providerConfiguration.providerName, forKey: "providerName")
        defaults.set(providerConfiguration.providerKind.rawValue, forKey: "providerKind")
        defaults.set(providerConfiguration.baseURL, forKey: "baseURL")
        defaults.set(providerConfiguration.model, forKey: "model")
        defaults.set(providerConfiguration.timeoutSeconds, forKey: "timeoutSeconds")
        defaults.set(providerConfiguration.customHeaders, forKey: "customHeaders")
        defaults.set(ocrEnabled, forKey: "ocrEnabled")
        KeychainHelper.save(service: service, account: "apiKey", value: providerConfiguration.apiKey)
    }
}
