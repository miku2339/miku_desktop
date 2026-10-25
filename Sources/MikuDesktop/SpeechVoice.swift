import Foundation

/// Which voice reads a reply: "yue" (Cantonese), "zh" (Mandarin), "ja" or "en".
///
/// The text decides first, so Mandarin text is never read in the Cantonese voice (or the
/// other way round), and Japanese or English text always gets its own voice. Chinese text
/// is told apart by its everyday words: Cantonese 係／唔／嘅／咗／喺／啲／佢／哋… against
/// Mandarin 的／了／嗎／這／那／們／什麼／沒有／很…. Only text that could be either (a short
/// 「好！」, a song title) follows the chosen language.
enum SpeechVoice {
    static let cantonese = "yue"
    static let mandarin = "zh"
    static let japanese = "ja"
    static let english = "en"

    /// `preferred`: the language Miku was asked to speak ("auto", "yue", "zh", "ja", "en").
    static func voice(for text: String, preferred: String) -> String {
        let spokenText = textOutsideQuotedTitles(in: text)
        let scalars = spokenText.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains(Int($0.value)) }) {
            return japanese
        }
        if scalars.contains(where: { (0x3400...0x9FFF).contains(Int($0.value)) }) {
            let yue = count(cantoneseWords, in: spokenText)
            let zh = count(mandarinWords, in: spokenText)
            if yue > zh { return cantonese }
            if zh > yue { return mandarin }
            return preferred == cantonese ? cantonese : mandarin
        }
        if scalars.contains(where: { (0x41...0x5A).contains(Int($0.value)) || (0x61...0x7A).contains(Int($0.value)) }) {
            return english
        }
        return [cantonese, mandarin, japanese, english].contains(preferred) ? preferred : mandarin
    }

    /// Chooses a Chinese voice from newest to oldest text. Unmarked Chinese, English and
    /// Japanese keep looking back so a short reply can follow the conversation's dialect.
    static func chineseVoice(for texts: [String]) -> String {
        for text in texts {
            let spokenText = textOutsideQuotedTitles(in: text)
            let scalars = spokenText.unicodeScalars
            let hasHan = scalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
            let hasKana = scalars.contains { (0x3040...0x30FF).contains(Int($0.value)) }
            guard hasHan, !hasKana else { continue }

            let yue = count(cantoneseWords, in: spokenText)
            let zh = count(mandarinWords, in: spokenText)
            if yue > zh { return cantonese }
            if zh > yue { return mandarin }
        }
        return mandarin
    }

    /// The voice that goes with Miku's chosen reply language, or nil when it's automatic.
    static func voice(forReplyLanguage value: String?) -> String? {
        switch value {
        case "yue": return cantonese
        case "zh-Hant": return mandarin
        case "ja": return japanese
        case "en": return english
        default: return nil
        }
    }

    // Words only (or almost only) one of them uses in everyday speech. 啦 and 呢 are left
    // out: Taiwanese Mandarin says 啦 all the time, and Cantonese 呢 means "this".
    private static let cantoneseWords = try! NSRegularExpression(
        pattern: "唔|冇|喺|嘅|咗|嚟|喇|啲|佢|哋|俾|畀|攞|睇|諗|瞓|攰|鍾意|鐘意|而家|點解|乜|噉|咁|嘢|㗎|㖭|吖|啱|傾|嗰|咩|真係|(?:你|我|佢|呢|就|都|唔|即)係"
    )
    private static let mandarinWords = try! NSRegularExpression(
        pattern: "的|了|嗎|吗|這|这|那|們|们|什麼|甚麼|什么|沒有|没有|沒|没|很|吧|怎麼|怎么|為什麼|为什么|一下|就是|現在|现在"
    )

    private static func count(_ expression: NSRegularExpression, in text: String) -> Int {
        expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static let quotedTitle = try! NSRegularExpression(
        pattern: "〈[^〉]*〉|《[^》]*》|「[^」]*」|『[^』]*』|“[^”]*”|‘[^’]*’|\"[^\"]*\""
    )

    private static func textOutsideQuotedTitles(in text: String) -> String {
        let outside = quotedTitle.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        let hasOutsideLanguage = outside.unicodeScalars.contains {
            let value = Int($0.value)
            return (0x3400...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
        }
        return hasOutsideLanguage ? outside : text
    }
}
