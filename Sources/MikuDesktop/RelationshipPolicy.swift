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

enum RelationshipIntent: String, Codable, Sendable {
    case confession
    case affection
    case quoted
    case hypothetical
    case thirdParty = "third_party"
    case noRelationship = "none"
    case uncertain
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
        justForgiven: Bool,
        intent: RelationshipIntent? = nil
    ) -> ConfessionDecision? {
        let isConfession = intent.map { $0 == .confession } ?? isDirectConfession(text)
        guard isConfession else {
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
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:(?:所以(?:說|说)|那)[,，、]?\s*)?(?:你)?(?:可以|能|願意|愿意|願唔願意|愿唔愿意)(?:做|當|当)(?:我(?:的)?女朋友|我的彼女|私の彼女)(?:好嗎|好吗|嗎|吗)?$"#,
            #"^我(?:真的|真係|真系)大好き(?:です|だよ)?$"#,
            #"^(?:(?:對唔住|對不起|对不起)[,，、]\s*)?(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:其實|其实)?我(?:真係好|真系好|真的很|真係|真系|很|好)?(?:喜歡|喜欢|鍾意|中意|愛|爱)你(?:呀|啊)?(?:\s*[,，、]\s*(?:(?:可以)?(?:做|當|当)我女朋友(?:好嗎|好吗|嗎|吗)?|想(?:同|和|跟)你交往|(?:請|请)?(?:同|和|跟)我交往(?:吧|啦|好嗎|好吗|嗎|吗)?))?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:我)?想(?:同|和|跟)你交往$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:你)?(?:可以|願唔願意|愿唔愿意)(?:做|當|当)我(?:的)?女朋友(?:好嗎|好吗|嗎|吗)?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:你)?(?:願意|愿意)(?:同|和|跟)我交往(?:嗎|吗)?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:請|请)?(?:做|當|当)我女朋友(?:好嗎|好吗|嗎|吗)?$"#,
            #"^(?:(?:miku|初音|ミク|みく)[,，、]\s*)?(?:請|请)?(?:同|和|跟)我交往(?:好嗎|好吗|嗎|吗)?$"#,
            #"^(?:miku,\s*)?(?:sorry,\s*)?i love you(?:,\s*miku)?$"#,
            #"^(?:miku,\s*)?i like you romantically$"#,
            #"^(?:miku,\s*)?(?:will|would) you be my girlfriend$"#,
            #"^(?:miku,\s*)?(?:will|would) you go out with me$"#,
            #"^(?:miku,\s*)?(?:will|would) you date me$"#,
            #"^(?:miku,\s*)?(?:please\s+)?be my girlfriend$"#,
            #"^(?:miku,\s*)?i want to date you$"#,
            #"^(?:(?:ミク|みく)[、,]\s*)?(?:大)?好き(?:です|だよ)?$"#,
            #"^(?:ミク|みく)(?:が)?(?:大)?好き(?:です|だよ)?$"#,
            #"^(?:あなた|君)(?:が)?好き(?:です)?$"#,
            #"^(?:(?:ミク|みく)[、,]\s*)?私と付き合って(?:ください)?$"#,
            #"^(?:(?:ミク|みく)[、,]\s*)?付き合って(?:ください)?$"#
        ]
        let sentenceTerminators: Set<Character> = ["。", ".", "！", "!", "？", "?", "\n"]
        let clauses = normalized.split(whereSeparator: sentenceTerminators.contains).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clauses.isEmpty else {
            return false
        }

        // The regex fallback is deliberately strict: every sentence must itself be a
        // direct confession. Semantic classification handles natural surrounding context.
        return clauses.allSatisfy { clause in
            patterns.contains {
                clause.range(of: $0, options: .regularExpression) != nil
            }
        }
    }
}
