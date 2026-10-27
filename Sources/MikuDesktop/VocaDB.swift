import Foundation

/// A song found on VocaDB (https://vocadb.net). Database content there is under Creative
/// Commons Attribution; lyrics are not, so they are never requested.
struct VocaDBSong: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let artistString: String
    let producers: [String]
    let vocalists: [String]
    /// "yyyy-MM-dd", when VocaDB has one.
    let published: String?
    let songType: String
    /// The original upload by the creator on YouTube, if listed.
    let youtube: URL?
    /// The original upload on niconico, if listed.
    let niconico: URL?

    var pageURL: URL { URL(string: "https://vocadb.net/S/\(id)")! }
}

enum VocaDB {
    static let host = "vocadb.net"

    /// The song search, with only the fields used here (no lyrics).
    static func searchURL(for title: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/songs"
        components.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "nameMatchMode", value: "Auto"),
            URLQueryItem(name: "fields", value: "Artists,PVs,Names"),
            URLQueryItem(name: "lang", value: "Default"),
            URLQueryItem(name: "sort", value: "RatingScore")
        ]
        return components.url
    }

    // MARK: - Response

    private struct Page: Decodable { let items: [Item] }
    private struct Item: Decodable {
        let id: Int
        let name: String
        let artistString: String?
        let songType: String?
        let publishDate: String?
        let artists: [Credit]?
        let pvs: [PV]?
        let names: [Name]?
    }
    private struct Credit: Decodable {
        let name: String?
        let categories: String?
        let isSupport: Bool?
    }
    private struct PV: Decodable {
        let service: String?
        let pvType: String?
        let url: String?
        let disabled: Bool?
    }
    private struct Name: Decodable { let value: String }

    /// The entry meant by `title`: an exact name match first (covers last), in rating order.
    static func bestMatch(in data: Data, for title: String) throws -> VocaDBSong? {
        let items = try JSONDecoder().decode(Page.self, from: data).items
        let wanted = folded(title)
        func names(_ item: Item) -> [String] { [item.name] + (item.names ?? []).map(\.value) }
        let exact = items.filter { names($0).contains { folded($0) == wanted } }
        let pool = exact.isEmpty ? items : exact
        let chosen = pool.first { $0.songType != "Cover" } ?? pool.first
        return chosen.map(song)
    }

    private static func song(_ item: Item) -> VocaDBSong {
        let credits = item.artists ?? []
        func people(_ category: String) -> [String] {
            credits.filter { ($0.categories ?? "").contains(category) && $0.isSupport != true }
                .compactMap { $0.name.map(clean) }
                .filter { !$0.isEmpty }
        }
        func original(_ service: String) -> URL? {
            (item.pvs ?? []).first { $0.service == service && $0.pvType == "Original" && $0.disabled != true }
                .flatMap { $0.url.flatMap(URL.init(string:)) }
                .flatMap(safeVideoURL)
        }
        return VocaDBSong(
            id: item.id,
            name: clean(item.name),
            artistString: clean(item.artistString ?? ""),
            producers: Array(people("Producer").prefix(4)),
            vocalists: Array(people("Vocalist").prefix(4)),
            published: item.publishDate.flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil },
            songType: item.songType ?? "Unspecified",
            youtube: original("Youtube"),
            niconico: original("NicoNicoDouga")
        )
    }

    /// Only plain YouTube and niconico video links are kept.
    static func safeVideoURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return MusicLinks.officialYouTubeVideo("https://www.youtube.com/watch?v=\(id)")
        }
        if ["www.youtube.com", "youtube.com", "m.youtube.com"].contains(host) {
            return MusicLinks.officialYouTubeVideo("https://www.youtube.com\(url.path)?\(url.query ?? "")")
        }
        if ["www.nicovideo.jp", "nicovideo.jp", "nico.ms"].contains(host) {
            let id = url.lastPathComponent
            guard id.range(of: #"^(?:sm|nm|so)\d{1,12}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.nicovideo.jp/watch/\(id)")
        }
        return nil
    }

    /// Text from VocaDB is data: one line, no control characters, bounded length.
    static func clean(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces).prefix(120).description
    }

    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\s♥♡☆★・･]"#, with: "", options: .regularExpression)
    }

    /// Other spellings worth one more search: Traditional Chinese characters in a Japanese
    /// title (「號哭」 for 「号哭」) and decorations VocaDB may not have.
    static func alternativeQuery(_ title: String) -> String? {
        let simplified = title.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? title
        if simplified != title { return simplified }
        return nil
    }

    // MARK: - Which song is being asked about

    /// The title in "你知道〇〇嗎" / "〇〇是誰寫的" / "do you know 〇〇" / "〇〇って知ってる".
    static func askedTitle(in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { return nil }
        if let quoted = firstCapture(#"[《「『〈“"]([^《》「」『』〈〉“”"]{1,60})[》」』〉”"]"#, in: value) { return quoted }
        let patterns = [
            #"(?:你|妳)?(?:知(?:道|唔知)|聽過|听过|識唔識|有冇聽過|有沒有聽過|認識|认识)\s*(.{1,60}?)\s*(?:這首歌|这首歌|呢首歌|這首|这首|呢首|嗎|吗|呀|嘛|未|冇|沒有|没有)?\s*[?？]?$"#,
            #"^(.{1,60}?)\s*(?:這首歌|这首歌|呢首歌)?\s*(?:是|係)?\s*(?:誰|谁|邊個|边个)\s*(?:寫|写|作|唱|做)"#,
            #"^(.{1,60}?)\s*(?:是|係)\s*(?:什麼|甚麼|什么|咩)\s*(?:歌|曲)"#,
            #"(?i)(?:do you know|have you heard(?: of)?|who (?:wrote|made|sang|composed))\s+(?:the song\s+)?(.{1,60}?)\s*[?.!]*$"#,
            #"^(.{1,60}?)\s*(?:って|を|は)\s*(?:知ってる|知ってます|知って|聴いたこと|誰の曲|誰が作)"#
        ]
        for pattern in patterns {
            if let found = firstCapture(pattern, in: value) {
                let title = found.trimmingCharacters(in: CharacterSet(charactersIn: " ，、,。.!！?？~～♪"))
                if title.count >= 2, !["這首歌", "这首歌", "呢首歌", "它", "佢", "this", "that", "it", "this song"].contains(title.lowercased()) {
                    return title
                }
            }
        }
        if let katakana = firstCapture(#"([ァ-ヶー・♥♡]{3,40})"#, in: value) { return katakana }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Looks songs up on VocaDB when the built-in knowledge has nothing. Off until you turn it on
/// in Settings; results are cached on this Mac and online lookups are capped per day.
actor VocaDBLookup {
    static let shared = VocaDBLookup()
    static let enabledKey = "vocadb.lookupEnabled"
    static let dailyLimit = 30

    private struct Cached: Codable {
        let fetchedAt: Date
        let song: VocaDBSong?
    }
    private struct CacheFile: Codable {
        var entries: [String: Cached] = [:]
        var day: String = ""
        var lookupsToday: Int = 0
    }

    typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let defaults: UserDefaults
    private let cacheURL: URL
    private let fetch: Fetcher
    private let now: @Sendable () -> Date
    private var cache: CacheFile

    private static let foundLifetime: TimeInterval = 30 * 24 * 3600
    private static let missingLifetime: TimeInterval = 3 * 24 * 3600
    private static let maximumEntries = 400
    private static let maximumResponseBytes = 1_000_000

    init(
        defaults: UserDefaults = .standard,
        applicationSupportDirectory: URL? = nil,
        fetch: Fetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheURL = base.appendingPathComponent("MikuDesktop/Knowledge/vocadb-cache.json")
        self.fetch = fetch ?? Self.liveFetch
        self.now = now
        cache = (try? JSONDecoder().decode(CacheFile.self, from: Data(contentsOf: cacheURL))) ?? CacheFile()
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The song for `title`, from the cache or VocaDB; nil when off, not found or unreachable.
    func song(for title: String) async -> VocaDBSong? {
        guard isEnabled else { return nil }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let key = VocaDB.folded(trimmed)
        guard !key.isEmpty else { return nil }
        if let cached = cache.entries[key] {
            let lifetime = cached.song == nil ? Self.missingLifetime : Self.foundLifetime
            if now().timeIntervalSince(cached.fetchedAt) < lifetime { return cached.song }
        }
        var found: VocaDBSong?
        var reachedVocaDB = false
        for query in [trimmed, VocaDB.alternativeQuery(trimmed)].compactMap({ $0 }) {
            guard takeLookupSlot(), let result = await search(query) else { break }
            reachedVocaDB = true
            if let song = result { found = song; break }
        }
        // Only remember answers VocaDB actually gave, not network failures.
        if reachedVocaDB { remember(found, for: key) }
        return found
    }

    /// Clears what was looked up (Settings: turning the lookup off).
    func clearCache() {
        cache = CacheFile()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Network

    /// nil: VocaDB couldn't be reached; .some(nil): it answered with no match.
    private func search(_ query: String) async -> VocaDBSong?? {
        guard let url = VocaDB.searchURL(for: query) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host?.lowercased() == VocaDB.host,
                  data.count <= Self.maximumResponseBytes else { return nil }
            return .some(try VocaDB.bestMatch(in: data, for: query))
        } catch {
            return nil
        }
    }

    private func takeLookupSlot() -> Bool {
        let today = Self.dayFormatter.string(from: now())
        if cache.day != today {
            cache.day = today
            cache.lookupsToday = 0
        }
        guard cache.lookupsToday < Self.dailyLimit else { return false }
        cache.lookupsToday += 1
        return true
    }

    private func remember(_ song: VocaDBSong?, for key: String) {
        cache.entries[key] = Cached(fetchedAt: now(), song: song)
        if cache.entries.count > Self.maximumEntries {
            let oldest = cache.entries.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(cache.entries.count - Self.maximumEntries)
            oldest.forEach { cache.entries.removeValue(forKey: $0.key) }
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "MikuDesktop/\(version) (+https://github.com/miku2339/miku_desktop)"
    }()

    private static let liveFetch: Fetcher = { request in
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// Follows a redirect only within vocadb.net over HTTPS.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard request.url?.scheme == "https", request.url?.host?.lowercased() == VocaDB.host else { return nil }
            return request
        }
    }
}
