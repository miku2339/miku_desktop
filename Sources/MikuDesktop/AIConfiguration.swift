import Combine
import Foundation

@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    /// The local AI (oMLX, Ollama…) on this Mac.
    @Published var endpoint: String
    @Published var model: String
    /// "local" or "cloud". In the cloud the user brings their own service and API key; the
    /// key itself lives only in the Keychain (CloudAIKey).
    @Published var provider: String
    @Published var cloudEndpoint: String
    @Published var cloudModel: String
    /// Whether what she notices (the app in front, the screen, what's playing) may go to the
    /// cloud service too. Off unless the user turns it on.
    @Published var cloudSharesAwareness: Bool
    @Published var personalityPreset: String
    @Published var customPersonality: String
    @Published var nickname: String
    @Published var replyLanguage: String
    @Published var interfaceLanguage: String
    @Published var launchAtLogin: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpoint = defaults.string(forKey: "endpoint") ?? "http://127.0.0.1:8000/v1"
        model = defaults.string(forKey: "model") ?? "Qwen3.5-0.8B-MLX-4bit"
        provider = defaults.string(forKey: "aiProvider") == "cloud" ? "cloud" : "local"
        cloudEndpoint = defaults.string(forKey: "cloudEndpoint") ?? ""
        cloudModel = defaults.string(forKey: "cloudModel") ?? ""
        cloudSharesAwareness = defaults.bool(forKey: "cloudSharesAwareness")
        personalityPreset = defaults.string(forKey: "personalityPreset") ?? "lively"
        customPersonality = defaults.string(forKey: "customPersonality") ?? ""
        nickname = defaults.string(forKey: "nickname") ?? ""
        replyLanguage = defaults.string(forKey: "replyLanguage") ?? "auto"
        interfaceLanguage = defaults.string(forKey: "interfaceLanguage") ?? "auto"
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
    }

    func save() {
        defaults.set(endpoint, forKey: "endpoint")
        defaults.set(model, forKey: "model")
        defaults.set(provider == "cloud" ? "cloud" : "local", forKey: "aiProvider")
        defaults.set(cloudEndpoint, forKey: "cloudEndpoint")
        defaults.set(cloudModel, forKey: "cloudModel")
        defaults.set(cloudSharesAwareness, forKey: "cloudSharesAwareness")
        defaults.set(personalityPreset, forKey: "personalityPreset")
        defaults.set(customPersonality, forKey: "customPersonality")
        defaults.set(nickname, forKey: "nickname")
        defaults.set(replyLanguage, forKey: "replyLanguage")
        defaults.set(interfaceLanguage, forKey: "interfaceLanguage")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
    }

    var usesCloud: Bool { provider == "cloud" }
    /// The service chat replies come from right now.
    var activeEndpoint: String { usesCloud ? cloudEndpoint : endpoint }
    var activeModel: String { usesCloud ? cloudModel : model }
    /// What she notices on this Mac stays on it unless the user lets the cloud see it too.
    var sharesAwarenessWithAI: Bool { !usesCloud || cloudSharesAwareness }
}

/// The user's own API key for a cloud AI service: only ever in the Keychain, never in the
/// settings, logs or diagnostics, and sent only to the cloud endpoint they set.
enum CloudAIKey {
    static let service = "com.qimake.MikuDesktop.cloudAI"
    static let account = "api-key"

    static func load(keychain: AIMCPKeychainStore = .system) -> String? {
        guard let data = try? keychain.read(service: service, account: account),
              let value = String(data: data, encoding: .utf8) else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func hasKey(keychain: AIMCPKeychainStore = .system) -> Bool {
        load(keychain: keychain) != nil
    }

    /// Saves the key; an empty one is ignored (use `clear` to remove it).
    static func save(_ candidate: String, keychain: AIMCPKeychainStore = .system) throws {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard key.count <= 4_096, !key.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.invalidAPIKey
        }
        try keychain.write(Data(key.utf8), service: service, account: account)
    }

    static func clear(keychain: AIMCPKeychainStore = .system) throws {
        try keychain.remove(service: service, account: account)
    }
}
