import Combine
import Foundation

@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    @Published var endpoint: String
    @Published var model: String
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
        defaults.set(personalityPreset, forKey: "personalityPreset")
        defaults.set(customPersonality, forKey: "customPersonality")
        defaults.set(nickname, forKey: "nickname")
        defaults.set(replyLanguage, forKey: "replyLanguage")
        defaults.set(interfaceLanguage, forKey: "interfaceLanguage")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
    }
}
