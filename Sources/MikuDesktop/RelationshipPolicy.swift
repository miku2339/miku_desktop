import Foundation

enum RelationshipStatus: String, Codable, Sendable {
    case friends
    case dating

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = RelationshipStatus(rawValue: rawValue) ?? .friends
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ConfessionDecision: String, Sendable {
    case accepted
    case notReady
    case upset
    case recovering
    case alreadyDating
}

enum ConfessionPolicy {
    static func evaluate(
        _ text: String,
        friendship: Double,
        status: RelationshipStatus,
        offended: Bool,
        justForgiven: Bool
    ) -> ConfessionDecision? {
        guard isDirectConfession(text) else {
            return nil
        }

        if offended {
            return .upset
        }
        if justForgiven {
            return .recovering
        }
        if status == .dating {
            return .alreadyDating
        }
        guard friendship.isFinite, friendship >= 75 else {
            return .notReady
        }
        return .accepted
    }

    private static func isDirectConfession(_ text: String) -> Bool {
        let normalized = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return false
        }

        let patterns = [
            #"^(?:(?:對唔住|對不起|对不起)[,，、]\s*)?(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:其實|其实)?我(?:真係好|真系好|真的很|真係|真系|很|好)?(?:喜歡|喜欢|鍾意|中意|愛|爱)你(?:\s*[,，、]\s*(?:(?:可以)?(?:做|當|当)我女朋友(?:好嗎|好吗|嗎|吗)?|想(?:同|和|跟)你交往|(?:同|和|跟)我交往(?:吧|啦|好嗎|好吗|嗎|吗)?))?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:我)?想(?:同|和|跟)你交往$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:請|请)?(?:做|當|当)我女朋友(?:好嗎|好吗|嗎|吗)?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:請|请)?(?:同|和|跟)我交往(?:好嗎|好吗|嗎|吗)?$"#,
            #"^(?:miku,\s*)?(?:sorry,\s*)?i love you(?:,\s*miku)?$"#,
            #"^(?:miku,\s*)?i like you romantically$"#,
            #"^(?:miku,\s*)?(?:will|would) you be my girlfriend$"#,
            #"^(?:miku,\s*)?(?:please\s+)?be my girlfriend$"#,
            #"^(?:miku,\s*)?i want to date you$"#,
            #"^(?:(?:ミク|みく)[、,]\s*)?(?:大)?好き(?:です|だよ)?$"#,
            #"^(?:ミク|みく)(?:が)?(?:大)?好き(?:です|だよ)?$"#,
            #"^(?:あなた|君)(?:が)?好き(?:です)?$"#,
            #"^(?:(?:ミク|みく)[、,]\s*)?付き合って(?:ください)?$"#
        ]
        let sentenceTerminators: Set<Character> = ["。", ".", "！", "!", "？", "?", "\n"]
        let clauses = normalized.split(whereSeparator: sentenceTerminators.contains)
        guard let finalClause = clauses.last else {
            return false
        }
        let candidate = String(finalClause).trimmingCharacters(in: .whitespacesAndNewlines)
        return patterns.contains {
            candidate.range(of: $0, options: .regularExpression) != nil
        }
    }
}
