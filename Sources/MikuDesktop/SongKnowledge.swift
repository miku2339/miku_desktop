import Foundation
import Security
import CryptoKit

struct AIMCPKeychainStore {
    typealias CopyMatching = ([String: Any]) -> (OSStatus, Any?)
    typealias Update = ([String: Any], [String: Any]) -> OSStatus
    typealias Add = ([String: Any]) -> OSStatus
    typealias Delete = ([String: Any]) -> OSStatus

    private let copyMatching: CopyMatching
    private let update: Update
    private let add: Add
    private let delete: Delete

    init(
        copyMatching: @escaping CopyMatching,
        update: @escaping Update,
        add: @escaping Add,
        delete: @escaping Delete
    ) {
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.delete = delete
    }

    #if AIMCP_TEST_KEYCHAIN_STUB
    static let system = AIMCPKeychainStore(
        copyMatching: { _ in (errSecItemNotFound, nil) },
        update: { _, _ in errSecNotAvailable },
        add: { _ in errSecNotAvailable },
        delete: { _ in errSecItemNotFound }
    )
    #else
    static let system = AIMCPKeychainStore(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { query in
            SecItemAdd(query as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
    #endif

    func contains(service: String, account: String) throws -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, _) = copyMatching(query)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(status)
        }
        return true
    }

    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(status)
        }
        guard let data = result as? Data else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(errSecDecode)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = update(query, attributes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(status)
        }

        var item = query
        item[kSecValueData as String] = data
        let addStatus = add(item)
        guard addStatus == errSecSuccess else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(addStatus)
        }
    }

    func remove(service: String, account: String) throws {
        let status = delete(baseQuery(service: service, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

enum AIMCPKnowledgeConfiguration {
    enum ConfigurationError: Error, Equatable {
        case invalidAPIKey
        case missingAPIKey
        case persistenceFailed
        case keychainFailure(OSStatus)
    }

    static let defaultEndpoint = "https://mikuwiki.qimake.com/api/v1/song-knowledge"
    static let keychainService = "com.qimake.MikuDesktop.aimcp"
    static let keychainAccount = "song-knowledge"

    static let endpoint = URL(string: defaultEndpoint)!

    static func hasAPIKey(keychain: AIMCPKeychainStore = .system) throws -> Bool {
        try keychain.contains(service: keychainService, account: keychainAccount)
    }

    static func apiKey(keychain: AIMCPKeychainStore = .system) throws -> String? {
        guard let data = try keychain.read(service: keychainService, account: keychainAccount) else { return nil }
        guard let value = String(data: data, encoding: .utf8), validAPIKey(value) else {
            throw ConfigurationError.invalidAPIKey
        }
        return value
    }

    static func save(apiKey candidate: String?, keychain: AIMCPKeychainStore = .system) throws {
        let trimmedKey = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedKey, !trimmedKey.isEmpty, !validAPIKey(trimmedKey) {
            throw ConfigurationError.invalidAPIKey
        }

        if let trimmedKey, !trimmedKey.isEmpty {
            try keychain.write(Data(trimmedKey.utf8), service: keychainService, account: keychainAccount)
        } else if try !hasAPIKey(keychain: keychain) {
            throw ConfigurationError.missingAPIKey
        }
    }

    static func clearAPIKey(keychain: AIMCPKeychainStore = .system) throws {
        try keychain.remove(service: keychainService, account: keychainAccount)
        guard try !hasAPIKey(keychain: keychain) else { throw ConfigurationError.persistenceFailed }
    }

    private static func validAPIKey(_ value: String) -> Bool {
        value.range(of: #"^aimcp_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }
}

enum SongKnowledgeKind: String, Codable, CaseIterable, Sendable {
    case song
    case performance
    case character
}

enum SongKnowledgeSourceStatus: String, Codable, Sendable {
    case bundled
    case remote
    case manual
    case online
}

struct SongKnowledgeReference: Decodable, Equatable, Sendable {
    let label: String
    let url: String
}

struct SongKnowledgeSearchResult: Sendable {
    let entries: [SongKnowledgeEntry]
    let searchedOnline: Bool
    let sources: [String: [SongKnowledgeReference]]
}

private struct AIMCPKnowledgeSearch: Decodable {
    struct Item: Decodable {
        struct Fact: Decodable {
            let label: String
            let value: String
        }

        let slug: String
        let type: String
        let title: String
        let originalTitle: String?
        let summary: String
        let content: String
        let facts: [Fact]
        let sources: [SongKnowledgeReference]
        let url: String
    }

    let version: Int
    let items: [Item]
}

struct SongKnowledgeText: Codable, Equatable, Sendable {
    let traditionalChinese: String
    let english: String
    let japanese: String
    let korean: String?

    init(traditionalChinese: String, english: String, japanese: String, korean: String? = nil) {
        self.traditionalChinese = traditionalChinese
        self.english = english
        self.japanese = japanese
        self.korean = korean
    }

    enum CodingKeys: String, CodingKey {
        case traditionalChinese = "zh-Hant"
        case english = "en"
        case japanese = "ja"
        case korean = "ko"
    }

    func value(for language: String) -> String {
        switch language {
        case "en": return english
        case "ja": return japanese
        case "ko": return korean.flatMap { $0.isEmpty ? nil : $0 } ?? english
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

private struct SongKnowledgePage {
    let document: SongKnowledgeDocument
    let total: Int?
    let nextCursor: String?
    let truncated: Bool?
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
    typealias Downloader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias APIKeyLoader = @Sendable () throws -> String?
    typealias EndpointLoader = @Sendable () throws -> URL

    enum SearchMatch {
        case library
        case title
    }

    enum UpdateSource: Equatable, Sendable {
        case aimcp
        case github
        case githubFallback
    }

    struct UpdateResult: Equatable, Sendable {
        let version: String
        let entryCount: Int
        let source: UpdateSource
    }

    struct ImportResult: Equatable, Sendable {
        let importedCount: Int
        let replacedCustomCount: Int
    }

    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/miku2339/miku_desktop/main/Resources/Knowledge/miku-knowledge.json"
    )!
    static let maximumDocumentSize = 1_048_576
    static let maximumCatalogSize = 64 * 1_048_576
    static let maximumCatalogEntries = 50_000
    static let shared = SongKnowledgeStore()

    private let updateURL: URL
    private let aimcpURL: URL
    private let customURL: URL
    private let preferencesURL: URL
    private let downloader: Downloader
    private let apiKeyLoader: APIKeyLoader
    private let endpointLoader: EndpointLoader
    private var bundled: SongKnowledgeDocument
    private var updated: SongKnowledgeDocument?
    private var aimcp: SongKnowledgeDocument?
    private var custom: SongKnowledgeDocument?
    private var favorites: Set<String>

    init(
        applicationSupportDirectory: URL? = nil,
        bundledURL: URL? = nil,
        downloader: Downloader? = nil,
        apiKeyLoader: APIKeyLoader? = nil,
        endpointLoader: EndpointLoader? = nil
    ) {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base
            .appendingPathComponent("MikuDesktop", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true)
        updateURL = folder.appendingPathComponent("miku-knowledge-updated.json")
        aimcpURL = folder.appendingPathComponent("miku-knowledge-aimcp.json")
        customURL = folder.appendingPathComponent("miku-knowledge-custom.json")
        preferencesURL = folder.appendingPathComponent("song-preferences.json")
        self.downloader = downloader ?? Self.defaultDownloader
        self.apiKeyLoader = apiKeyLoader ?? { try AIMCPKnowledgeConfiguration.apiKey() }
        self.endpointLoader = endpointLoader ?? { AIMCPKnowledgeConfiguration.endpoint }

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
        aimcp = Self.loadDocument(
            at: aimcpURL,
            sourceStatus: .remote,
            maximumSize: Self.maximumCatalogSize,
            maximumEntries: Self.maximumCatalogEntries
        )
        custom = Self.loadDocument(at: customURL, sourceStatus: .manual)
        favorites = Self.loadFavorites(at: preferencesURL)
    }

    func allEntries() -> [SongKnowledgeEntry] {
        effectiveEntries().sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    func search(matching query: String, language: String = "zh-Hant", match: SearchMatch = .library) async throws -> SongKnowledgeSearchResult {
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            return SongKnowledgeSearchResult(entries: [], searchedOnline: false, sources: [:])
        }
        let local = allEntries().filter { entry in
            if match == .title {
                return entry.aliases.contains { VocaDB.folded($0) == VocaDB.folded(title) }
            }
            return ([entry.id, entry.content.traditionalChinese, entry.content.english, entry.content.japanese]
                + [entry.content.korean].compactMap { $0 } + entry.aliases + entry.creators)
                .contains { $0.localizedCaseInsensitiveContains(title) }
        }
        if !local.isEmpty {
            return SongKnowledgeSearchResult(entries: local, searchedOnline: false, sources: [:])
        }
        guard let apiKey = try apiKeyLoader() else {
            return SongKnowledgeSearchResult(entries: [], searchedOnline: false, sources: [:])
        }
        try Task.checkCancellation()
        var components = URLComponents(url: AIMCPKnowledgeConfiguration.endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/api/v1/knowledge"
        components.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "type", value: "song"),
            URLQueryItem(name: "lang", value: language == "zh-Hant" ? "zh-TW" : language),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { throw SongKnowledgeError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await downloader(request)
        try Task.checkCancellation()
        guard data.count <= Self.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        guard let http = response as? HTTPURLResponse else { throw SongKnowledgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SongKnowledgeError.httpStatus(http.statusCode) }
        guard response.url == request.url else { throw SongKnowledgeError.invalidResponse }
        let result: AIMCPKnowledgeSearch
        do { result = try JSONDecoder().decode(AIMCPKnowledgeSearch.self, from: data) }
        catch { throw SongKnowledgeError.invalidJSON }
        guard result.version == 1, result.items.count <= 5 else { throw SongKnowledgeError.invalidResponse }
        var entries: [SongKnowledgeEntry] = []
        var sources: [String: [SongKnowledgeReference]] = [:]
        var seen = Set<String>()
        let creatorLabels = ["creator", "producer", "produced by", "production credits", "創作者", "製作者", "制作者", "參與製作", "製作參與", "制作参加", "プロデューサー", "제작자", "프로듀서", "제작 참여"]
        for item in result.items {
            guard item.type == "song", item.slug.count <= 100, item.slug.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
                  let source = URL(string: item.url), source.scheme == "https", source.host == "mikuwiki.qimake.com",
                  source.port == nil, source.user == nil, source.password == nil, source.path == "/wiki/\(item.slug)",
                  item.facts.count <= 50, item.sources.count <= 50 else {
                throw SongKnowledgeError.invalidResponse
            }
            let simpleID = "song.\(item.slug)"
            let digest = SHA256.hash(data: Data(item.slug.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = simpleID.count <= 64 ? simpleID : "song.wiki.\(digest.prefix(32))"
            guard seen.insert(id).inserted else { throw SongKnowledgeError.duplicateID(id) }
            let clean: (String, Int) -> String = { text, maximum in
                let scalars = text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" }
                return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum).description
            }
            var aliases: [String] = []
            for name in [item.title, item.originalTitle ?? "", item.slug] {
                let value = clean(name, 120)
                if !value.isEmpty, !aliases.contains(value) { aliases.append(value) }
            }
            let content = clean([item.summary, item.content].joined(separator: "\n\n"), 1_000)
            guard !aliases.isEmpty, !content.isEmpty else { throw SongKnowledgeError.invalidResponse }
            let creators = item.facts.filter { creatorLabels.contains($0.label.lowercased()) }
                .map { clean($0.value, 120) }.filter { !$0.isEmpty }
            let references = item.sources.filter { reference in
                guard let url = URL(string: reference.url) else { return false }
                return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            }
            entries.append(SongKnowledgeEntry(
                id: id, aliases: aliases, creators: Array(creators.prefix(16)), kind: .song,
                content: SongKnowledgeText(traditionalChinese: content, english: content, japanese: content),
                sourceURL: source.absoluteString, featured: false, sourceStatus: .online
            ))
            sources[id] = references
        }
        return SongKnowledgeSearchResult(entries: entries, searchedOnline: true, sources: sources)
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
        if let apiKey = try apiKeyLoader() {
            let endpoint = try endpointLoader()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            do {
                let document = try await downloadAIMCPCatalog(request)
                return try install(document, source: .aimcp)
            } catch {
                if case let SongKnowledgeError.httpStatus(status) = error,
                   status == 401 || status == 403 || status == 429 {
                    throw error
                }
                guard Self.allowsGitHubFallback(error) else { throw error }
                return try await downloadAndInstallGitHub(source: .githubFallback)
            }
        }
        return try await downloadAndInstallGitHub(source: .github)
    }

    private func downloadAndInstallGitHub(source: UpdateSource) async throws -> UpdateResult {
        var request = URLRequest(url: Self.remoteURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let document = try await downloadDocument(request)
        return try install(document, source: source)
    }

    private func downloadAIMCPCatalog(_ baseRequest: URLRequest) async throws -> SongKnowledgeDocument {
        var entries: [SongKnowledgeEntry] = []
        var ids = Set<String>()
        var seenCursors = Set<String>()
        var expectedVersion: String?
        var expectedTotal: Int?
        var cursor: String?
        var receivedBytes = 0
        var pageCount = 0

        repeat {
            pageCount += 1
            guard pageCount <= 1_000 else { throw SongKnowledgeError.invalidResponse }
            var request = baseRequest
            request.url = try Self.paginatedURL(baseRequest.url, cursor: cursor)
            let (data, response) = try await downloader(request)
            receivedBytes += data.count
            guard receivedBytes <= Self.maximumCatalogSize else { throw SongKnowledgeError.tooLarge }
            let page = try Self.validatedPage(data, response: response, request: request)

            guard let total = page.total else {
                guard cursor == nil else { throw SongKnowledgeError.invalidResponse }
                return page.document
            }
            guard total >= 0, total <= Self.maximumCatalogEntries,
                  page.truncated == (page.nextCursor != nil) else {
                throw SongKnowledgeError.invalidSchema("invalid pagination metadata")
            }
            if let expectedVersion, expectedVersion != page.document.version {
                throw SongKnowledgeError.invalidSchema("snapshot version changed during pagination")
            }
            if let expectedTotal, expectedTotal != total {
                throw SongKnowledgeError.invalidSchema("catalog total changed during pagination")
            }
            expectedVersion = page.document.version
            expectedTotal = total
            for entry in page.document.entries {
                guard ids.insert(entry.id).inserted else { throw SongKnowledgeError.duplicateID(entry.id) }
                entries.append(entry)
            }
            guard entries.count <= total else {
                throw SongKnowledgeError.invalidSchema("pagination returned more entries than total")
            }
            if let nextCursor = page.nextCursor {
                guard !nextCursor.isEmpty, nextCursor.count <= 512,
                      seenCursors.insert(nextCursor).inserted else {
                    throw SongKnowledgeError.invalidSchema("pagination cursor repeated")
                }
                cursor = nextCursor
            } else {
                guard entries.count == total else {
                    throw SongKnowledgeError.invalidSchema("pagination ended before total")
                }
                return SongKnowledgeDocument(
                    schemaVersion: 1,
                    version: page.document.version,
                    entries: entries
                )
            }
        } while true
    }

    private static func paginatedURL(_ url: URL?, cursor: String?) throws -> URL {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SongKnowledgeError.invalidResponse
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "pageSize" || $0.name == "cursor" || $0.name == "collection" }
        items.append(URLQueryItem(name: "collection", value: "popular"))
        items.append(URLQueryItem(name: "pageSize", value: "250"))
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        guard let result = components.url else { throw SongKnowledgeError.invalidResponse }
        return result
    }

    private func downloadDocument(_ request: URLRequest) async throws -> SongKnowledgeDocument {
        let (data, response) = try await downloader(request)
        let page = try Self.validatedPage(data, response: response, request: request)
        guard page.nextCursor == nil, page.truncated != true,
              page.total == nil || page.total == page.document.entries.count else {
            throw SongKnowledgeError.invalidSchema("incomplete paginated document")
        }
        return page.document
    }

    private static func validatedPage(
        _ data: Data,
        response: URLResponse,
        request: URLRequest
    ) throws -> SongKnowledgePage {
        guard data.count <= Self.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
        guard let http = response as? HTTPURLResponse else { throw SongKnowledgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SongKnowledgeError.httpStatus(http.statusCode) }
        guard response.url == request.url else { throw SongKnowledgeError.invalidResponse }
        var page = try Self.decodePageAndValidate(data)
        var document = page.document
        document.entries = document.entries.map { entry in
            var copy = entry
            copy.sourceStatus = .remote
            return copy
        }
        page = SongKnowledgePage(
            document: document,
            total: page.total,
            nextCursor: page.nextCursor,
            truncated: page.truncated
        )
        return page
    }

    private func install(_ document: SongKnowledgeDocument, source: UpdateSource) throws -> UpdateResult {
        switch source {
        case .aimcp:
            try save(
                document,
                to: aimcpURL,
                maximumSize: Self.maximumCatalogSize,
                maximumEntries: Self.maximumCatalogEntries
            )
            aimcp = document
        case .github, .githubFallback:
            try save(document, to: updateURL)
            updated = document
        }
        return UpdateResult(version: document.version, entryCount: document.entries.count, source: source)
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
        let data = try encoder.encode(document)
        _ = try Self.decodeAndValidate(data)
        return data
    }

    func activeVersion() -> String {
        effectiveVersion()
    }

    private func effectiveVersion() -> String {
        aimcp?.version ?? updated?.version ?? bundled.version
    }

    private func effectiveEntries() -> [SongKnowledgeEntry] {
        let base = updated ?? bundled
        var byID = Dictionary(uniqueKeysWithValues: base.entries.map { ($0.id, $0) })
        aimcp?.entries.forEach { remote in
            guard let existing = byID[remote.id] else {
                byID[remote.id] = remote
                return
            }
            var seenAliases = Set<String>()
            let aliases = (remote.aliases + existing.aliases).filter { seenAliases.insert($0).inserted }
            byID[remote.id] = SongKnowledgeEntry(
                id: remote.id,
                aliases: aliases,
                creators: remote.creators,
                kind: remote.kind,
                content: remote.content,
                sourceURL: remote.sourceURL,
                featured: existing.featured || remote.featured,
                sourceStatus: remote.sourceStatus
            )
        }
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

    private func save(
        _ document: SongKnowledgeDocument,
        to url: URL,
        maximumSize: Int = SongKnowledgeStore.maximumDocumentSize,
        maximumEntries: Int = 1_000
    ) throws {
        guard document.entries.count <= maximumEntries else {
            throw SongKnowledgeError.invalidSchema("too many entries")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumSize else { throw SongKnowledgeError.tooLarge }
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
        let page = try decodePageAndValidate(data)
        guard page.nextCursor == nil, page.truncated != true,
              page.total == nil || page.total == page.document.entries.count else {
            throw SongKnowledgeError.invalidSchema("incomplete paginated document")
        }
        return page.document
    }

    private static func decodePageAndValidate(
        _ data: Data,
        maximumSize: Int = maximumDocumentSize,
        maximumEntries: Int = 1_000
    ) throws -> SongKnowledgePage {
        guard data.count <= maximumSize else { throw SongKnowledgeError.tooLarge }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw SongKnowledgeError.invalidJSON }
        guard let root = json as? [String: Any] else { throw SongKnowledgeError.invalidSchema("root must be an object") }
        let rootKeys = Set(root.keys)
        let legacyKeys: Set<String> = ["schemaVersion", "version", "entries"]
        let paginatedKeys = legacyKeys.union(["total", "nextCursor", "truncated"])
        guard rootKeys == legacyKeys || rootKeys == paginatedKeys else {
            try requireExactKeys(rootKeys, expected: legacyKeys, path: "root")
            throw SongKnowledgeError.invalidSchema("invalid pagination fields")
        }
        guard let rawEntries = root["entries"] as? [[String: Any]] else {
            throw SongKnowledgeError.invalidSchema("entries must be an array")
        }
        guard rawEntries.count <= maximumEntries else { throw SongKnowledgeError.invalidSchema("too many entries") }
        for (index, entry) in rawEntries.enumerated() {
            try requireExactKeys(
                Set(entry.keys),
                expected: ["id", "aliases", "creators", "kind", "content", "sourceURL", "featured", "sourceStatus"],
                path: "entries[\(index)]"
            )
            guard let content = entry["content"] as? [String: Any] else {
                throw SongKnowledgeError.invalidSchema("entries[\(index)].content must be an object")
            }
            let contentKeys = Set(content.keys)
            let legacyContentKeys: Set<String> = ["zh-Hant", "en", "ja"]
            guard contentKeys == legacyContentKeys || contentKeys == legacyContentKeys.union(["ko"]) else {
                try requireExactKeys(contentKeys, expected: legacyContentKeys, path: "entries[\(index)].content")
                throw SongKnowledgeError.invalidSchema("invalid localized content fields")
            }
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
                  Self.validText(entry.content.japanese, maximum: 1_000),
                  entry.content.korean.map({ Self.validText($0, maximum: 1_000) }) ?? true else {
                throw SongKnowledgeError.invalidSchema("invalid localized content for \(entry.id)")
            }
            guard let source = URL(string: entry.sourceURL),
                  Self.isTrustedSourceURL(source),
                  source.user == nil, source.password == nil else {
                throw SongKnowledgeError.invalidSourceURL(entry.sourceURL)
            }
        }
        var total: Int?
        var nextCursor: String?
        var truncated: Bool?
        if rootKeys == paginatedKeys {
            guard let decodedTotal = root["total"] as? Int,
                  let decodedTruncated = root["truncated"] as? Bool,
                  root["nextCursor"] is NSNull || root["nextCursor"] is String else {
                throw SongKnowledgeError.invalidSchema("invalid pagination metadata")
            }
            total = decodedTotal
            nextCursor = root["nextCursor"] as? String
            truncated = decodedTruncated
        }
        return SongKnowledgePage(
            document: document,
            total: total,
            nextCursor: nextCursor,
            truncated: truncated
        )
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximum && !trimmed.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" }
    }

    private static func isTrustedSourceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && host == "127.0.0.1")
    }

    private static func requireExactKeys(_ actual: Set<String>, expected: Set<String>, path: String) throws {
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            let unknown = actual.subtracting(expected).sorted().joined(separator: ", ")
            throw SongKnowledgeError.invalidSchema("\(path) keys; missing [\(missing)], unknown [\(unknown)]")
        }
    }

    private static func loadDocument(
        at url: URL?,
        sourceStatus: SongKnowledgeSourceStatus,
        maximumSize: Int = maximumDocumentSize,
        maximumEntries: Int = 1_000
    ) -> SongKnowledgeDocument? {
        guard let url, let data = try? Data(contentsOf: url),
              let page = try? decodePageAndValidate(
                data,
                maximumSize: maximumSize,
                maximumEntries: maximumEntries
              ),
              page.nextCursor == nil, page.truncated != true,
              page.total == nil || page.total == page.document.entries.count else { return nil }
        var document = page.document
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

    private static func allowsGitHubFallback(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error {
        case SongKnowledgeError.tooLarge,
             SongKnowledgeError.invalidJSON,
             SongKnowledgeError.invalidSchema,
             SongKnowledgeError.duplicateID,
             SongKnowledgeError.invalidSourceURL,
             SongKnowledgeError.invalidResponse:
            return true
        case let SongKnowledgeError.httpStatus(status):
            return status == 404 || status >= 500
        default:
            return false
        }
    }

    private static let defaultDownloader: Downloader = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: SongKnowledgeNoRedirectDelegate(),
            delegateQueue: nil
        )
        let (bytes, response) = try await session.bytes(for: request)
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
