import Foundation

enum SongKnowledgeKind: String, Codable, CaseIterable, Sendable {
    case song
    case performance
    case character
}

enum SongKnowledgeSourceStatus: String, Codable, Sendable {
    case bundled
    case remote
    case manual
}

struct SongKnowledgeText: Codable, Equatable, Sendable {
    let traditionalChinese: String
    let english: String
    let japanese: String

    enum CodingKeys: String, CodingKey {
        case traditionalChinese = "zh-Hant"
        case english = "en"
        case japanese = "ja"
    }

    func value(for language: String) -> String {
        switch language {
        case "en": return english
        case "ja": return japanese
        default: return traditionalChinese
        }
    }
}

struct SongKnowledgeEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let aliases: [String]
    let creators: [String]
    let kind: SongKnowledgeKind
    let content: SongKnowledgeText
    let sourceURL: String
    let featured: Bool
    var sourceStatus: SongKnowledgeSourceStatus

    var displayTitle: String { aliases.first ?? id }

    func text(for language: String) -> String {
        content.value(for: language)
    }
}

struct SongKnowledgeDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: String
    var entries: [SongKnowledgeEntry]
}

enum SongKnowledgeError: LocalizedError, Equatable {
    case missingBundledData
    case tooLarge
    case invalidJSON
    case invalidSchema(String)
    case duplicateID(String)
    case invalidSourceURL(String)
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBundledData: return "The bundled knowledge file is missing."
        case .tooLarge: return "The knowledge file is larger than 1 MB."
        case .invalidJSON: return "The knowledge file is not valid JSON."
        case let .invalidSchema(reason): return "Invalid knowledge schema: \(reason)"
        case let .duplicateID(id): return "Duplicate knowledge ID: \(id)"
        case let .invalidSourceURL(value): return "Invalid source URL: \(value)"
        case let .httpStatus(status): return "The update server returned HTTP \(status)."
        case .invalidResponse: return "The update server returned an invalid response."
        }
    }
}

private final class SongKnowledgeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor SongKnowledgeStore {
    typealias Downloader = @Sendable (URL) async throws -> (Data, URLResponse)

    struct UpdateResult: Equatable, Sendable {
        let version: String
        let entryCount: Int
    }

    struct ImportResult: Equatable, Sendable {
        let importedCount: Int
        let replacedCustomCount: Int
    }

    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/miku2339/miku_desktop/main/Resources/Knowledge/miku-knowledge.json"
    )!
    static let maximumDocumentSize = 1_048_576
    static let shared = SongKnowledgeStore()

    private let updateURL: URL
    private let customURL: URL
    private let preferencesURL: URL
    private let downloader: Downloader
    private var bundled: SongKnowledgeDocument
    private var updated: SongKnowledgeDocument?
    private var custom: SongKnowledgeDocument?
    private var favorites: Set<String>

    init(
        applicationSupportDirectory: URL? = nil,
        bundledURL: URL? = nil,
        downloader: Downloader? = nil
    ) {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base
            .appendingPathComponent("MikuDesktop", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true)
        updateURL = folder.appendingPathComponent("miku-knowledge-updated.json")
        customURL = folder.appendingPathComponent("miku-knowledge-custom.json")
        preferencesURL = folder.appendingPathComponent("song-preferences.json")
        self.downloader = downloader ?? Self.defaultDownloader

        let sourceURL = bundledURL ?? Bundle.main.url(
            forResource: "miku-knowledge",
            withExtension: "json",
            subdirectory: "Knowledge"
        )
        bundled = Self.loadDocument(at: sourceURL, sourceStatus: .bundled) ?? SongKnowledgeDocument(
            schemaVersion: 1,
            version: "missing",
            entries: []
        )
        updated = Self.loadDocument(at: updateURL, sourceStatus: .remote)
        custom = Self.loadDocument(at: customURL, sourceStatus: .manual)
        favorites = Self.loadFavorites(at: preferencesURL)
    }

    func allEntries() -> [SongKnowledgeEntry] {
        effectiveEntries().sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    func entries(matching query: String, previousUserMessages: [String] = []) -> [SongKnowledgeEntry] {
        let resolved = resolvedQuery(query, previousUserMessages: previousUserMessages)
        var matches = titleMatches(in: resolved)
        if resolved.localizedCaseInsensitiveContains("ハローセカイ") {
            matches.removeAll { $0.id == "song.sekai" }
        }
        let asksFor39Song = containsTerm("39", in: resolved)
            && containsAny(resolved, ["歌", "歌曲", "曲", "song"])
            && !resolved.localizedCaseInsensitiveContains("39みゅーじっく")
        if asksFor39Song,
           let song39 = effectiveEntries().first(where: { $0.id == "song.39" }),
           !matches.contains(where: { $0.id == song39.id }) {
            matches.append(song39)
        }
        if !matches.isEmpty { return unique(matches) }
        return unique(effectiveEntries().filter { entry in
            entry.creators.contains { containsTerm($0, in: resolved) }
        })
    }

    func featuredEntries() -> [SongKnowledgeEntry] {
        effectiveEntries()
            .filter { $0.kind == .song && $0.featured }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    func favoriteEntries() -> [SongKnowledgeEntry] {
        let byID = Dictionary(uniqueKeysWithValues: effectiveEntries().map { ($0.id, $0) })
        return favorites.compactMap { byID[$0] }.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains(id)
    }

    func setFavorite(_ favorite: Bool, id: String) throws {
        guard effectiveEntries().contains(where: { $0.id == id }) else {
            throw SongKnowledgeError.invalidSchema("unknown favorite ID \(id)")
        }
        let previous = favorites
        if favorite { favorites.insert(id) } else { favorites.remove(id) }
        do {
            try saveFavorites()
        } catch {
            favorites = previous
            throw error
        }
    }

    @discardableResult
    func recordExplicitPreference(
        in text: String,
        previousUserMessages: [String] = []
    ) throws -> SongKnowledgeEntry? {
        guard Self.explicitlyLikesSong(text) else { return nil }
        var candidates = titleMatches(in: text)
        if candidates.isEmpty, Self.isReferential(text), let previous = previousUserMessages.last {
            candidates = titleMatches(in: previous)
        }
        candidates = unique(candidates.filter { $0.kind == .song })
        guard candidates.count == 1, let entry = candidates.first else { return nil }
        let previous = favorites
        favorites.insert(entry.id)
        do {
            try saveFavorites()
        } catch {
            favorites = previous
            throw error
        }
        return entry
    }

    func checkForUpdates() async throws -> UpdateResult {
        let (data, response) = try await downloader(Self.remoteURL)
        guard data.count <= Self.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        guard let http = response as? HTTPURLResponse else { throw SongKnowledgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SongKnowledgeError.httpStatus(http.statusCode) }
        guard response.url == Self.remoteURL else { throw SongKnowledgeError.invalidResponse }
        var document = try Self.decodeAndValidate(data)
        document.entries = document.entries.map { entry in
            var copy = entry
            copy.sourceStatus = .remote
            return copy
        }
        try save(document, to: updateURL)
        updated = document
        return UpdateResult(version: document.version, entryCount: document.entries.count)
    }

    func importJSON(_ data: Data) throws -> ImportResult {
        guard data.count <= Self.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        var incoming = try Self.decodeAndValidate(data)
        incoming.entries = incoming.entries.map { entry in
            var copy = entry
            copy.sourceStatus = .manual
            return copy
        }
        let existing = custom?.entries ?? []
        let existingIDs = Set(existing.map(\.id))
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        incoming.entries.forEach { merged[$0.id] = $0 }
        let next = SongKnowledgeDocument(
            schemaVersion: 1,
            version: incoming.version,
            entries: merged.values.sorted { $0.id < $1.id }
        )
        try save(next, to: customURL)
        custom = next
        return ImportResult(
            importedCount: incoming.entries.count,
            replacedCustomCount: incoming.entries.filter { existingIDs.contains($0.id) }.count
        )
    }

    func exportJSON() throws -> Data {
        let document = SongKnowledgeDocument(
            schemaVersion: 1,
            version: effectiveVersion(),
            entries: effectiveEntries().sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    func activeVersion() -> String {
        effectiveVersion()
    }

    private func effectiveVersion() -> String {
        updated?.version ?? bundled.version
    }

    private func effectiveEntries() -> [SongKnowledgeEntry] {
        let base = updated ?? bundled
        var byID = Dictionary(uniqueKeysWithValues: base.entries.map { ($0.id, $0) })
        custom?.entries.forEach { byID[$0.id] = $0 }
        return Array(byID.values)
    }

    private func titleMatches(in query: String) -> [SongKnowledgeEntry] {
        effectiveEntries().filter { entry in
            entry.aliases.contains { containsTerm($0, in: query) }
        }
    }

    private func resolvedQuery(_ query: String, previousUserMessages: [String]) -> String {
        guard Self.isReferential(query), let previous = previousUserMessages.last else { return query }
        return previous + "\n" + query
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { containsTerm($0, in: text) }
    }

    private func containsTerm(_ term: String, in text: String) -> Bool {
        let normalizedTerm = term.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        let normalizedText = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        let isASCII = normalizedTerm.unicodeScalars.allSatisfy(\.isASCII)
        guard isASCII else { return normalizedText.localizedCaseInsensitiveContains(normalizedTerm) }
        let escaped = NSRegularExpression.escapedPattern(for: normalizedTerm)
        let pattern = #"(?<![A-Za-z0-9])"# + escaped + #"(?![A-Za-z0-9])"#
        return normalizedText.range(of: pattern, options: .regularExpression) != nil
    }

    private func unique(_ entries: [SongKnowledgeEntry]) -> [SongKnowledgeEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func saveFavorites() throws {
        let data = try JSONEncoder().encode(favorites.sorted())
        try Self.atomicWrite(data, to: preferencesURL)
    }

    private func save(_ document: SongKnowledgeDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        try Self.atomicWrite(data, to: url)
    }

    private static func explicitlyLikesSong(_ text: String) -> Bool {
        let lowered = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        let negative = [
            "不喜歡", "不喜欢", "唔鍾意", "唔中意", "不太喜歡", "不是我喜歡", "不是我喜欢",
            "唔係我鍾意", "唔係我中意", "don't like", "do not like", "not my favorite",
            "not a song i like", "isn't a song i like", "is not a song i like",
            "嫌い", "好きじゃない", "好きではない", "私が好きな曲ではない"
        ].contains { lowered.contains($0) }
        guard !negative else { return false }
        let asks = [
            "你喜歡", "你喜欢", "你鍾意", "你中意", "只是問", "只係問",
            "do you like", "just asking if you like", "好きですか", "好き？", "好きか聞"
        ]
            .contains { lowered.contains($0) }
        guard !asks else { return false }
        let patterns = [
            #"(?:我|本人)\s*(?:(?:很|好|真係|真的|最|特別|特别|非常|超級|超级|超|也|一直|都|其實|其实)\s*)*(?:喜歡|喜欢|鍾意|中意|愛|爱)"#,
            #"(?:這首歌?|这首歌?|呢首|嗰首)\s*(?:是|係)?\s*(?:我(?:的)?(?:最愛|最爱)|my\s+favou?rite)"#,
            #"\bi\s+(?:really\s+)?(?:like|love|adore)\b"#,
            #"\bmy\s+favou?rite\b"#,
            #"(?:この曲|その曲|これ|それ|私は|僕は|わたしは).{0,12}(?:大好き|好き|お気に入り)"#
        ]
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isReferential(_ text: String) -> Bool {
        let lowered = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return [
            "呢首", "這首", "这首", "嗰首", "那首", "this song", "that song", "this one", "that one",
            "この曲", "その曲", "これ", "それ"
        ].contains { lowered.contains($0) }
    }

    static func decodeAndValidate(_ data: Data) throws -> SongKnowledgeDocument {
        guard data.count <= maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw SongKnowledgeError.invalidJSON }
        guard let root = json as? [String: Any] else { throw SongKnowledgeError.invalidSchema("root must be an object") }
        try requireExactKeys(Set(root.keys), expected: ["schemaVersion", "version", "entries"], path: "root")
        guard let rawEntries = root["entries"] as? [[String: Any]] else {
            throw SongKnowledgeError.invalidSchema("entries must be an array")
        }
        guard rawEntries.count <= 1_000 else { throw SongKnowledgeError.invalidSchema("too many entries") }
        for (index, entry) in rawEntries.enumerated() {
            try requireExactKeys(
                Set(entry.keys),
                expected: ["id", "aliases", "creators", "kind", "content", "sourceURL", "featured", "sourceStatus"],
                path: "entries[\(index)]"
            )
            guard let content = entry["content"] as? [String: Any] else {
                throw SongKnowledgeError.invalidSchema("entries[\(index)].content must be an object")
            }
            try requireExactKeys(Set(content.keys), expected: ["zh-Hant", "en", "ja"], path: "entries[\(index)].content")
        }
        let document: SongKnowledgeDocument
        do { document = try JSONDecoder().decode(SongKnowledgeDocument.self, from: data) }
        catch { throw SongKnowledgeError.invalidSchema(error.localizedDescription) }
        guard document.schemaVersion == 1 else { throw SongKnowledgeError.invalidSchema("unsupported schemaVersion") }
        guard document.version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$"#, options: .regularExpression) != nil else {
            throw SongKnowledgeError.invalidSchema("invalid version")
        }
        var ids = Set<String>()
        for entry in document.entries {
            guard entry.id.range(of: #"^[a-z0-9][a-z0-9._-]{1,63}$"#, options: .regularExpression) != nil else {
                throw SongKnowledgeError.invalidSchema("invalid ID \(entry.id)")
            }
            guard ids.insert(entry.id).inserted else { throw SongKnowledgeError.duplicateID(entry.id) }
            guard !entry.aliases.isEmpty, entry.aliases.count <= 24,
                  entry.aliases.allSatisfy({ Self.validText($0, maximum: 120) }) else {
                throw SongKnowledgeError.invalidSchema("invalid aliases for \(entry.id)")
            }
            guard entry.creators.count <= 16,
                  entry.creators.allSatisfy({ Self.validText($0, maximum: 120) }) else {
                throw SongKnowledgeError.invalidSchema("invalid creators for \(entry.id)")
            }
            guard Self.validText(entry.content.traditionalChinese, maximum: 1_000),
                  Self.validText(entry.content.english, maximum: 1_000),
                  Self.validText(entry.content.japanese, maximum: 1_000) else {
                throw SongKnowledgeError.invalidSchema("invalid localized content for \(entry.id)")
            }
            guard let source = URL(string: entry.sourceURL),
                  source.scheme == "https", source.host != nil,
                  source.user == nil, source.password == nil else {
                throw SongKnowledgeError.invalidSourceURL(entry.sourceURL)
            }
        }
        return document
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximum && !trimmed.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" }
    }

    private static func requireExactKeys(_ actual: Set<String>, expected: Set<String>, path: String) throws {
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            let unknown = actual.subtracting(expected).sorted().joined(separator: ", ")
            throw SongKnowledgeError.invalidSchema("\(path) keys; missing [\(missing)], unknown [\(unknown)]")
        }
    }

    private static func loadDocument(at url: URL?, sourceStatus: SongKnowledgeSourceStatus) -> SongKnowledgeDocument? {
        guard let url, let data = try? Data(contentsOf: url), var document = try? decodeAndValidate(data) else { return nil }
        document.entries = document.entries.map { entry in
            var copy = entry
            copy.sourceStatus = sourceStatus
            return copy
        }
        return document
    }

    private static func loadFavorites(at url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              data.count <= 65_536,
              let ids = try? JSONDecoder().decode([String].self, from: data),
              ids.count <= 1_000 else { return [] }
        return Set(ids.filter { $0.range(of: #"^[a-z0-9][a-z0-9._-]{1,63}$"#, options: .regularExpression) != nil })
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    private static let defaultDownloader: Downloader = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: SongKnowledgeNoRedirectDelegate(),
            delegateQueue: nil
        )
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > Int64(maximumDocumentSize) {
            throw SongKnowledgeError.tooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumDocumentSize))
        }
        for try await byte in bytes {
            guard data.count < maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
