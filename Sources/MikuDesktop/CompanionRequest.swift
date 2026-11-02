import Foundation

enum CompanionRequest {
    static func isComeOver(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let prefix = #"^(?:miku|初音(?:未來|未来|ミク)?|ミク|미쿠(?:야)?|하츠네\s*미쿠)[\s，、,：:!！~～]*"#
        value = value.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
            .replacingOccurrences(of: "能不能", with: "可以")
            .replacingOccurrences(of: "可不可以", with: "可以")
        guard !["不要", "不用", "不必", "別", "别", "不想", "不准", "不可以", "不能",
                "don't", "dont", "do not", "not come", "来ないで", "こないで", "来なくて", "ほしくない", "오지 마", "오지마", "오지 말", "오지말", "오지 않아", "오지 말아", "와 주지 마", "와주지 마", "와 주지마", "와주지마"]
            .contains(where: value.contains) else { return false }
        let requests = [
            #"^(?:(?:請|请|你|妳|可以|能不能|可不可以|能|快|先|麻煩你|麻烦你)\s*)*(?:走)?(?:過來|过来)(?=$|一下|這裡|这里|陪我|看看|到我|好嗎|好吗|嗎|吗|吧|嘛|呀|喔|哦|[\s，,。.!！?？~～])"#,
            #"^(?:(?:please|can you|could you|would you|will you)[\s,]+)*come\s+(?:here|over|closer)\b"#,
            #"^(?:여기(?:로)?|이리(?:로)?|내\s*(?:옆|곁)(?:으로|에)|가까이)\s*(?:와(?:\s*줘|줄래|줄래요|요)?|와봐|오렴|오세요)(?=$|[\s,.!?~♪]|줄래|줘)"#,
            #"^(?:こっち(?:に)?|ここに|そばに|側に|近くに)(?:来て|きて|おいで)"#
        ]
        return requests.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
