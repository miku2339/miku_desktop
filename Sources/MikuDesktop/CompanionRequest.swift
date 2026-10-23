import Foundation

enum CompanionRequest {
    static func isComeOver(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let prefix = #"^(?:miku|初音(?:未來|未来|ミク)?|ミク)[\s，、,：:!！~～]*"#
        value = value.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
            .replacingOccurrences(of: "能不能", with: "可以")
            .replacingOccurrences(of: "可不可以", with: "可以")
        guard !["不要", "不用", "不必", "別", "别", "不想", "不准", "不可以", "不能",
                "don't", "dont", "do not", "not come", "来ないで", "こないで", "来なくて", "ほしくない"]
            .contains(where: value.contains) else { return false }
        let requests = [
            #"^(?:(?:請|请|你|妳|可以|能不能|可不可以|能|快|先|麻煩你|麻烦你)\s*)*(?:走)?(?:過來|过来)(?=$|一下|這裡|这里|陪我|看看|到我|好嗎|好吗|嗎|吗|吧|嘛|呀|喔|哦|[\s，,。.!！?？~～])"#,
            #"^(?:(?:please|can you|could you|would you|will you)[\s,]+)*come\s+(?:here|over|closer)\b"#,
            #"^(?:こっち(?:に)?|ここに|そばに|側に|近くに)(?:来て|きて|おいで)"#
        ]
        return requests.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
