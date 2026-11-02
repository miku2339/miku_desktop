import Foundation

@main
struct LocalizationTests {
    private static var checks = 0
    private static var failures = 0

    static func main() throws {
        expect(AppLanguage.resolve(stored: "auto", preferredLanguages: ["ko-KR", "en-US"]) == .korean,
               "系統韓語自動選擇韓語介面")
        expect(AppLanguage.resolve(stored: nil, preferredLanguages: ["KO"]) == .korean,
               "未設定時接受韓語語系代碼")
        expect(AppLanguage.resolve(stored: "ja", preferredLanguages: ["ko-KR"]) == .japanese,
               "明確設定仍優先於系統語言")
        expect(AppLanguage.resolve(stored: "ko", preferredLanguages: ["zh-TW"]) == .korean,
               "明確選擇韓語不受系統語言影響")
        expect(AppLanguage.resolve(stored: "invalid", preferredLanguages: ["ko-KR"]) == .korean,
               "無效設定回到系統韓語")
        expect(AppLanguage.resolve(stored: "auto", preferredLanguages: ["zh-TW"]) == .traditionalChinese,
               "保留繁體中文選擇")
        expect(AppLanguage.resolve(stored: "auto", preferredLanguages: ["fr-FR"]) == .english,
               "未支援的系統語言仍回退英文")
        expect(L10n.text("settingsTitle", language: .korean) == "미쿠 설정", "韓語設定標題")
        expect(L10n.text("memoryEraseWord", language: .korean) == "초기화", "韓語清除記憶確認詞")
        expect(L10n.text("missing-localization-key", language: .korean) == "missing-localization-key", "保留未知鍵回退行為")

        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let keyPattern = try NSRegularExpression(pattern: #"(?m)^\s*"([^"]+)":\s*\["#)
        let keys = keyPattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        expect(!keys.isEmpty, "列舉介面翻譯鍵")
        for key in keys {
            let korean = L10n.text(key, language: .korean)
            let english = L10n.text(key, language: .english)
            expect(korean.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "韓文介面翻譯完整：\(key)")
            expect(korean.components(separatedBy: "%@").count == english.components(separatedBy: "%@").count,
                   "格式參數數量一致：\(key)")
        }
        print("\(checks) checks, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
