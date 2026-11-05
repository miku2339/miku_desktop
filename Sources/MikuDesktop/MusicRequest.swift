import Foundation

/// Where a song you ask for is opened.
enum MusicPlatform: String, CaseIterable, Sendable {
    case youtube
    case spotify
    case appleMusic

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

/// "Play Tell Your World on Spotify": what to play, and where if you said.
struct MusicRequest: Equatable, Sendable {
    /// Empty when you only asked to open the service ("打開 Spotify").
    let query: String
    let platform: MusicPlatform?
}

/// What will be opened once she has answered.
struct MusicPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// An official video from the song knowledge base: it plays straight away.
        case officialVideo(URL)
        case youtubeSearch
        /// Spotify only lets an account's API start a search result, so this opens the search.
        case spotifySearch
        /// Plays the song if it is in your Music library, otherwise opens the search.
        case appleMusicLibrary
        /// Nothing named: just open the service.
        case openService
    }

    let platform: MusicPlatform
    let mode: Mode
    /// Shown to her and used for searching ("Tell Your World livetune").
    let title: String
    let searchTerms: String
}

/// Recognises a request to play something from what you typed. Deterministic, so a reply
/// never starts music you didn't ask for.
enum MusicRequestParser {
    /// `recentAssistant`: her earlier lines, newest first, where a song she named may be.
    static func parse(
        _ text: String,
        previousAssistant: String? = nil,
        recentAssistant: [String] = [],
        knownTitles: [String] = []
    ) -> MusicRequest? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard !value.isEmpty, value.count <= 160 else { return nil }
        value = value.replacingOccurrences(
            of: #"^(?:miku|初音(?:未來|未来|ミク)?|ミク|미쿠(?:야)?|하츠네\s*미쿠)[\s，、,：:!！~～]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let lower = value.lowercased()
        let negations = ["不要", "不用", "不想", "別", "别", "唔好", "唔使", "唔想", "停", "關掉", "关掉",
                         "don't", "dont", "do not", "stop", "止めて", "やめて", "ないで", "틀지 마", "틀지마", "재생하지 마", "재생하지마", "켜지 마", "켜지마", "열지 마", "열지마", "듣기 싫", "듣고 싶지 않", "끄지 마", "멈춰"]
        guard !negations.contains(where: lower.contains) else { return nil }

        let platform = detectPlatform(in: lower)
        // The song she named lately ("推薦你聽《ロストワンの號哭》"), for "打開吧" / "播佢" / "好".
        let referenced = ([previousAssistant].compactMap { $0 } + recentAssistant).lazy
            .compactMap { lastTitle(in: $0, knownTitles: knownTitles) }
            .first

        // "好啊！" — she offered a song and you said yes.
        if let referenced, let previousAssistant, offersToPlay(previousAssistant), isAffirmative(value) {
            return MusicRequest(query: referenced, platform: platform)
        }

        let rest = removingPlatform(from: removingAcknowledgement(from: value))

        // "打開 Spotify" / "open YouTube": the song she just named, or else just the service.
        if let platform,
           rest.replacingOccurrences(of: #"[\s，、,。.!！?？~～]|請|请|幫我|帮我|你|可以|能不能|一下|吧|啦|嗎|吗|please|can you|could you|ください|부탁해|주세요|줘|줄래|요"#,
                                     with: "", options: [.regularExpression, .caseInsensitive]).isEmpty,
           value.range(of: #"打開|打开|開|开|open|launch|開いて|起動|열어|켜|실행"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return MusicRequest(query: referenced ?? "", platform: platform)
        }

        if let command = command(in: rest) {
            let query = cleaned(command.query)
            if query.isEmpty || isPointer(query) {
                if let referenced { return MusicRequest(query: referenced, platform: platform) }
                guard query.isEmpty else { return nil }
                return platform.map { MusicRequest(query: "", platform: $0) }
            }
            guard !isExcluded(query) else { return nil }
            guard command.strong || platform != nil || quoted(command.query)
                    || mentionsKnownTitle(query, knownTitles) else { return nil }
            return MusicRequest(query: query, platform: platform)
        }

        // "你想聽哪一首？" — "tell your world": a song name given as the answer.
        if let previousAssistant, asksWhatToPlay(previousAssistant) {
            let query = cleaned(rest)
            // "你看看！？" / "猜猜看？": a question back, not a title (cleaning drops the "？").
            guard !query.isEmpty, query.count <= 60, !isExcluded(query), !isPointer(query), !isNonAnswer(query),
                  !rest.contains("?"), !rest.contains("？") else { return nil }
            return MusicRequest(query: query, platform: platform)
        }
        return nil
    }

    /// The last song title in her line: 《…》 first, then 「…」 right after a music word
    /// (搜尋「…」, 推薦你聽「…」), then a title she knows, then 『…』. Other 「…」 are left
    /// out: she also uses them for quoted feelings (「你並不孤單」).
    static func lastTitle(in text: String, knownTitles: [String]) -> String? {
        if let marked = lastCapture(#"[《〈]([^《》〈〉]{1,60})[》〉]"#, in: text) { return marked }
        let musicWords = #"(?:搜尋|搜索|搜|聽|听|播放|播|放|點播|点播|推薦|推荐|歌曲|這首|这首|呢首|首歌|曲|search(?:ing)? for|play|listen to|を検索|検索|聴いて|かけ|流し|노래|곡|추천|재생|검색)"#
        if let named = lastCapture(musicWords + #"\s*「([^「」]{1,60})」"#, in: text) { return named }
        if let named = lastCapture(
            #"[「“\"]([^「」“”\"]{1,60})[」”\"](?:을|를)?\s*(?:추천|들어\s*볼|틀어\s*줄|재생|검색)"#, in: text
        ) { return named }
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        var best: (position: String.Index, title: String)?
        for title in knownTitles where !title.isEmpty {
            let term = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            guard let range = folded.range(of: term, options: .backwards) else { continue }
            if best == nil || range.lowerBound > best!.position { best = (range.lowerBound, title) }
        }
        if let best { return best.title }
        return lastCapture(#"『([^『』]{1,60})』"#, in: text)
    }

    private static func lastCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: text) else { return nil }
        let title = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func offersToPlay(_ text: String) -> Bool {
        let pattern = #"要(?:不要)?(?:試試|试试|聽|听)|試試看|试试看|要唔要|聽唔聽|想聽嗎|想听吗|要聽嗎|要听吗|聽聽看|听听看|播給你|放給你|推薦你聽|推荐你听|want to (?:try|listen|hear)|shall i (?:play|put)|should i play|give it a (?:try|listen)|聴いてみる|聴いてみない|かけようか|流そうか|들어\s*볼래|들어\s*볼까|들어볼래|들어볼까|틀어\s*줄까|재생해\s*줄까"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isAffirmative(_ value: String) -> Bool {
        let pattern = #"^(?:好啊|好呀|好吖|好的|好喔|好哦|好喇|好啦|好吧|好|可以啊|可以呀|可以|要|想|想聽|想听|聽|听|行|ok|okay|yes|yeah|sure|please|嗯嗯|嗯|うん|いいよ|はい|ええ|聴く|聴きたい|응|네|좋아|좋아요|그래|그래요|들을래)[\s，、,。.!！~～♪]*$"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Drops a leading "好啊，" / "OK, " so the request after it is read on its own.
    private static func removingAcknowledgement(from value: String) -> String {
        let pattern = #"^(?:好啊|好呀|好吖|好的|好喔|好哦|好喇|好啦|好吧|好|可以啊|可以呀|可以|行|ok|okay|yes|yeah|sure|嗯嗯|嗯|うん|いいよ|はい|ええ|응|네|좋아|좋아요|그래|그래요)(?:[\s，、,。.!！~～]+|(?=用|在|喺|幫|帮|播|開|打開|打开|放|請|请|play|open|put))"#
        return value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// "它" / "this one" / "それ": the song meant is the one she just named.
    private static func isPointer(_ query: String) -> Bool {
        ["它", "佢", "牠", "這首", "这首", "呢首", "那首", "嗰首", "這個", "这个", "呢個", "那個", "那个", "這首歌", "那首歌",
         "this", "that", "it", "this one", "that one", "this song", "that song", "それ", "これ", "その曲", "この曲", "그거", "이거", "그 곡", "이 곡", "그 노래", "이 노래"]
            .contains(query.lowercased())
    }

    static func detectPlatform(in lower: String) -> MusicPlatform? {
        if lower.range(of: #"apple\s*musi(?:c)?|apple\s*音樂|apple\s*音乐|蘋果音樂|苹果音乐|アップルミュージック|애플\s*뮤직"#, options: .regularExpression) != nil {
            return .appleMusic
        }
        if lower.range(of: #"spotify|スポティファイ|스포티파이"#, options: .regularExpression) != nil { return .spotify }
        if lower.range(of: #"you\s*tube|油管|ユーチューブ|유튜브"#, options: .regularExpression) != nil { return .youtube }
        return nil
    }

    // MARK: - Pieces

    private static let platformPattern = #"(?:apple\s*musi(?:c)?|apple\s*音樂|apple\s*音乐|蘋果音樂|苹果音乐|アップルミュージック|애플\s*뮤직|spotify|スポティファイ|스포티파이|you\s*tube|油管|ユーチューブ|유튜브)"#

    private static func removingPlatform(from value: String) -> String {
        let pattern = #"(?:(?:用|在|去|到|喺|開|打開|打开|上|on|in|with|from|using|via)\s*)?"# + platformPattern
            + #"\s*(?:上面|上|入面|裡面|里面|裡|里|度|app|應用|应用|에서|으로|로|에|で|から|の)?"#
        return value.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Command {
        let query: String
        /// "播" / "play" / "流して" are clearly about music; "放" / "開" / "聽" need more to go on.
        let strong: Bool
    }

    private static func command(in value: String) -> Command? {
        let politeZH = #"^(?:(?:請|请|麻煩你|麻烦你|麻煩|麻烦|幫我|帮我|幫|帮|替我|同我|你|妳|可以|能不能|可不可以|能|給我|给我|我要|我想|就|先|再)\s*)*"#
        let strongZH = politeZH + #"(?:播放|播)(?:一下|一首|首|下)?\s*(?<q>.*)$"#
        let weakZH = politeZH + #"(?:放|開|打開|打开|點|点|來|来|聽|听)(?:一下|一首|首|下)?\s*(?<q>.*)$"#
        let strongEN = #"^(?:(?:please|can you|could you|would you|will you|hey|ok|okay)[\s,]+)*(?:play|put on)\s+(?<q>.*)$"#
        let weakEN = #"^(?:(?:please|can you|could you|would you|will you|hey|ok|okay)[\s,]+)*(?:open|listen to|i want to hear|i'd like to hear)\s*(?<q>.*)$"#
        let strongJA = #"^(?<q>.*?)\s*(?:を)?\s*(?:流して|再生して|かけて|聴かせて|聞かせて|流そう|再生)(?:ください|くれる|くれない|ほしい|欲しい|よ|ね)?[?？!！。〜～\s]*$"#
        let weakJA = #"^(?<q>.*?)\s*(?:を)?\s*(?:開いて|聴きたい|聞きたい)(?:ください|な|よ|です)?[?？!！。〜～\s]*$"#
        let strongKO = #"^(?:제발\s*)?(?<q>.*?)\s*(?:을|를)?\s*(?:틀어|재생해|들려줘|들려)(?:\s*(?:줘|주세요|줄래|줄래요|줘요))?[?？!！。~～\s]*$"#
        let weakKO = #"^(?:제발\s*)?(?<q>.*?)\s*(?:을|를)?\s*(?:열어|듣고\s*싶어|듣고\s*싶어요)(?:\s*(?:줘|주세요|줄래|줄래요|줘요))?[?？!！。~～\s]*$"#
        for (pattern, strong) in [(strongKO, true), (weakKO, false), (strongZH, true), (strongEN, true), (strongJA, true), (weakZH, false), (weakEN, false), (weakJA, false)] {
            if let query = capture(pattern, in: value) { return Command(query: query, strong: strong) }
        }
        return nil
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(withName: "q"), in: value) else { return nil }
        return String(value[range])
    }

    private static func cleaned(_ value: String) -> String {
        var query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let edges = [
            #"^(?:一首|首|一下|下|首歌|些|the song|song|a song)\s*"#,
            #"[\s,，、。.!！?？~～♪]+$"#,
            #"\s*(?:for me|please|吧|啦|喇|呀|啊|呢|喔|哦|嘛|好嗎|好吗|好不好|得唔得|嗎|吗|一下|來聽|来听|聽聽|听听|給我聽|给我听|俾我聽|ください|して)$"#,
            #"\s*(?:這首歌|这首歌|呢首歌|首歌|的歌|嘅歌|歌曲|這首|这首|呢首|的曲|の曲|曲)$"#,
            #"[\s,，、。.!！?？~～♪]+$"#
        ]
        for _ in 0..<2 {
            for pattern in edges {
                query = query.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        query = query.trimmingCharacters(in: CharacterSet(charactersIn: "《》「」『』\"'“”‘’〈〉【】 "))
        return query.count <= 100 ? query : ""
    }

    private static func quoted(_ value: String) -> Bool {
        value.range(of: #"[《「『"“].+[》」』"”]"#, options: .regularExpression) != nil
    }

    private static func mentionsKnownTitle(_ query: String, _ titles: [String]) -> Bool {
        let folded = query.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return titles.contains { title in
            let term = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            return !term.isEmpty && folded.contains(term)
        }
    }

    /// Not a song: games, "with me", or a pointer at something said earlier.
    private static func isExcluded(_ query: String) -> Bool {
        let lower = query.lowercased()
        let notMusic = ["game", "with me", "together", "遊戲", "游戏", "ゲーム", "게임", "이야기", "얘기", "동화", "가위바위보", "猜拳", "包剪揼", "じゃんけん"]
        if notMusic.contains(where: lower.contains) { return true }
        return false
    }

    private static func isNonAnswer(_ query: String) -> Bool {
        let lower = query.lowercased()
        return ["隨便", "随便", "都可以", "都得", "是但", "你推薦", "你推荐", "你揀", "你拣", "你決定", "你决定", "你選", "你选",
                "不知道", "唔知", "whatever", "anything", "you choose", "you pick", "なんでも", "任せる", "まかせる", "わからない",
                "好", "好啊", "好呀", "好的", "嗯", "ok", "okay", "yes", "no", "うん", "はい", "아무거나", "상관없어", "모르겠어", "추천해", "골라줘", "좋아", "응", "네", "아니",
                // Asking her to look or guess ("what am I listening to? — you look!").
                "你看看", "看看", "你看", "你猜", "猜猜", "猜猜看", "你說呢", "你说呢", "你覺得呢", "你觉得呢", "你自己看", "你睇下", "你估",
                "guess", "you guess", "you tell me", "take a look", "look", "当てて", "当ててみて", "見て", "みて", "맞혀봐", "봐봐"]
            .contains { lower == $0 || lower.hasPrefix($0) && lower.count <= $0.count + 2 }
    }

    static func asksWhatToPlay(_ text: String) -> Bool {
        let pattern = #"想聽哪|想听哪|聽哪|听哪|想聽甚麼|想聽什麼|想听什么|聽甚麼歌|聽什麼歌|听什么歌|聽咩|聽邊首|听哪首|哪一首|點歌|点歌|what (?:song|would you like to (?:hear|listen))|which song|what should (?:i|we) play|何を聴|何聴|どの曲|何の曲|リクエスト|어떤\s*(?:노래|곡)|무슨\s*(?:노래|곡)|뭐\s*들|뭘\s*들"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Links for each service. Searches go to the service you asked for and nowhere else.
enum MusicLinks {
    static func youtubeSearch(_ terms: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: terms)]
        return components?.url
    }

    static func spotifyAppSearch(_ terms: String) -> URL? {
        guard let encoded = terms.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }

    static func spotifyWebSearch(_ terms: String) -> URL? {
        guard let encoded = terms.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "https://open.spotify.com/search/\(encoded)")
    }

    static func appleMusicSearch(_ terms: String) -> URL? {
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: terms)]
        return components?.url
    }

    static let youtubeHome = URL(string: "https://www.youtube.com/")!
    static let spotifyWeb = URL(string: "https://open.spotify.com/")!

    /// Only a plain YouTube watch link counts as an official video to play directly.
    static func officialYouTubeVideo(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host?.lowercased(),
              ["www.youtube.com", "youtube.com", "m.youtube.com"].contains(host),
              components.path == "/watch",
              let id = components.queryItems?.first(where: { $0.name == "v" })?.value,
              id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }
}
