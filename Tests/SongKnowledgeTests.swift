import Foundation
import Security

private final class FakeAIMCPKeychain {
    var item: Data?
    var copyStatus: OSStatus?
    var updateStatus: OSStatus?
    var addStatus: OSStatus?
    var deleteStatus: OSStatus?
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var updateQueries: [([String: Any], [String: Any])] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    init(item: Data? = nil) {
        self.item = item
    }

    var store: AIMCPKeychainStore {
        AIMCPKeychainStore(
            copyMatching: { [self] query in
                copyQueries.append(query)
                if let copyStatus { return (copyStatus, nil) }
                guard let item else { return (errSecItemNotFound, nil) }
                return query[kSecReturnData as String] as? Bool == true
                    ? (errSecSuccess, item)
                    : (errSecSuccess, nil)
            },
            update: { [self] query, attributes in
                updateQueries.append((query, attributes))
                if let updateStatus { return updateStatus }
                guard item != nil else { return errSecItemNotFound }
                item = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { [self] query in
                addQueries.append(query)
                if let addStatus { return addStatus }
                guard item == nil else { return errSecDuplicateItem }
                item = query[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { [self] query in
                deleteQueries.append(query)
                if let deleteStatus { return deleteStatus }
                guard item != nil else { return errSecItemNotFound }
                item = nil
                return errSecSuccess
            }
        )
    }
}

private actor FakeKnowledgeDownloader {
    enum Failure: Error { case offline }

    var data: Data
    var status: Int
    var responseURL: URL?
    var shouldFail = false
    private(set) var calls = 0
    private(set) var requests: [URLRequest] = []

    init(data: Data, status: Int = 200, responseURL: URL? = nil) {
        self.data = data
        self.status = status
        self.responseURL = responseURL
    }

    func set(data: Data? = nil, status: Int? = nil, responseURL: URL? = nil, shouldFail: Bool? = nil) {
        if let data { self.data = data }
        if let status { self.status = status }
        if let responseURL { self.responseURL = responseURL }
        if let shouldFail { self.shouldFail = shouldFail }
    }

    func download(_ request: URLRequest) throws -> (Data, URLResponse) {
        calls += 1
        requests.append(request)
        if shouldFail { throw Failure.offline }
        let response = HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private actor SequencedKnowledgeDownloader {
    var pages: [Data]
    private(set) var requests: [URLRequest] = []

    init(pages: [Data]) {
        self.pages = pages
    }

    func download(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard requests.count <= pages.count else { throw URLError(.badServerResponse) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (pages[requests.count - 1], response)
    }
}

private actor RoutedKnowledgeDownloader {
    enum AIMCPFailure {
        case offline
        case status(Int)
    }

    let aimcpURL: URL
    let githubData: Data
    let aimcpFailure: AIMCPFailure
    private(set) var requests: [URLRequest] = []

    init(aimcpURL: URL, githubData: Data, aimcpFailure: AIMCPFailure) {
        self.aimcpURL = aimcpURL
        self.githubData = githubData
        self.aimcpFailure = aimcpFailure
    }

    func download(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        if url.scheme == aimcpURL.scheme && url.host == aimcpURL.host && url.path == aimcpURL.path {
            switch aimcpFailure {
            case .offline:
                throw URLError(.notConnectedToInternet)
            case let .status(status):
                return (
                    Data(),
                    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
                )
            }
        }
        return (
            githubData,
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        )
    }
}

@main
struct SongKnowledgeTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    static func entry(
        id: String,
        title: String,
        aliases: [String]? = nil,
        creator: String = "Verified Creator",
        sourceURL: String = "https://example.com/source",
        content: String? = nil,
        korean: String? = nil,
        kind: SongKnowledgeKind = .song,
        featured: Bool = false,
        status: SongKnowledgeSourceStatus = .bundled
    ) -> SongKnowledgeEntry {
        let value = content ?? "\(title) — \(creator)."
        return SongKnowledgeEntry(
            id: id,
            aliases: aliases ?? [title],
            creators: [creator],
            kind: kind,
            content: SongKnowledgeText(traditionalChinese: value, english: value, japanese: value, korean: korean),
            sourceURL: sourceURL,
            featured: featured,
            sourceStatus: status
        )
    }

    static func document(version: String, entries: [SongKnowledgeEntry]) -> SongKnowledgeDocument {
        SongKnowledgeDocument(schemaVersion: 1, version: version, entries: entries)
    }

    static func data(_ document: SongKnowledgeDocument) -> Data {
        try! JSONEncoder().encode(document)
    }

    static func pageData(
        version: String,
        entries: [SongKnowledgeEntry],
        total: Int,
        nextCursor: String?,
        truncated: Bool
    ) -> Data {
        var root = try! JSONSerialization.jsonObject(with: data(document(version: version, entries: entries))) as! [String: Any]
        root["total"] = total
        root["nextCursor"] = nextCursor ?? NSNull()
        root["truncated"] = truncated
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miku-song-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func expectThrows(_ message: String, _ operation: () throws -> Void) {
        checks += 1
        do {
            try operation()
            failures.append("\(message): did not throw")
        } catch {}
    }

    static func main() async {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundledURL = projectRoot.appendingPathComponent("Resources/Knowledge/miku-knowledge.json")
        do {
            let bundledData = try Data(contentsOf: bundledURL)
            let bundled = try SongKnowledgeStore.decodeAndValidate(bundledData)
            expect(bundled.entries.count == 204, "bundled knowledge contains the verified song, character, and performance entries")
            expect(bundled.entries.allSatisfy { !$0.sourceURL.isEmpty }, "every bundled entry has a source URL")
            expect(Set(bundled.entries.map(\.kind)) == Set(SongKnowledgeKind.allCases), "bundled knowledge covers all supported entry kinds")
            expect(
                bundled.entries.first(where: { $0.id == "song.polestar" })?.sourceURL == "https://www.nicovideo.jp/watch/sm46743769",
                "Polestar points to the author's authoritative Nico upload"
            )

            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = SongKnowledgeStore(applicationSupportDirectory: folder, bundledURL: bundledURL)
            let song39 = await store.entries(matching: "歌曲 39 是誰寫的？")
            expect(song39.first?.id == "song.39", "standalone song 39 resolves to 39, not a positional hardcoded entry")
            let music39 = await store.entries(matching: "39みゅーじっく！")
            expect(music39.first?.id == "song.39-music", "39みゅーじっく remains distinct")
            let helloSekai = await store.entries(matching: "ハローセカイ")
            expect(!helloSekai.contains { $0.id == "song.sekai" }, "ハローセカイ does not collide with セカイ")
            let sensation = await store.entries(matching: "你知道思春期♥センセーション嗎")
            expect(sensation.first?.id == "song.shishunki-sensation", "思春期♥センセーション resolves to its verified entry")
            expect(sensation.first?.creators == ["まだ仔"], "思春期♥センセーション is credited to まだ仔")
            let plainHeart = await store.entries(matching: "思春期センセーション是誰寫的")
            expect(plainHeart.first?.id == "song.shishunki-sensation", "the title without the heart also resolves")
            let classics = await store.entries(matching: "你知道初音ミクの消失嗎")
            expect(classics.contains { $0.id == "song.disappearance" && $0.creators.first == "cosMo@暴走P" },
                   "初音ミクの消失 is found and credited to cosMo@暴走P")
            let alien = await store.entries(matching: "play Alien Alien")
            expect(alien.first?.id == "song.alien-alien", "an English title finds the song")
            expect(bundled.entries.allSatisfy { entry in
                ["www.nicovideo.jp", "www.youtube.com", "vocadb.net", "blog.piapro.net", "karent.jp", "pjsekai.sega.jp", "piapro.net", "magicalmirai.com", "snowmiku.com"]
                    .contains(URL(string: entry.sourceURL)?.host ?? "")
            }, "every bundled entry links to a known source")
            expect(Set(bundled.entries.map(\.id)).count == bundled.entries.count, "bundled ids are unique")
            expect(bundled.entries.filter { $0.kind == .song }.count == 200, "the knowledge base has 200 songs")
            let worldsEnd = await store.entries(matching: "你知道ワールズエンド・ダンスホール嗎")
            expect(worldsEnd.first?.creators.first == "wowaka", "a VocaDB-derived classic is found with its creator")
            let everyday = await store.entries(matching: "我們打勾勾，指切り！Goodbye～")
            expect(everyday.isEmpty, "everyday words are not mistaken for song titles")
            let adult = bundled.entries.filter { $0.content.traditionalChinese.contains("成人向") }
            expect(adult.allSatisfy { !$0.featured }, "adult-oriented songs are never recommended")
            let featured = await store.featuredEntries()
            expect(!featured.contains { $0.id == "song.shishunki-sensation" }, "the adult-oriented song is never offered as a recommendation")
        } catch {
            failures.append("bundled knowledge validates: \(error)")
        }

        expectThrows("corrupt JSON is rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(Data("{".utf8))
        }
        let duplicate = document(version: "1.0", entries: [entry(id: "song.same", title: "A"), entry(id: "song.same", title: "B")])
        expectThrows("duplicate IDs are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(data(duplicate))
        }
        let badURL = document(version: "1.0", entries: [entry(id: "song.bad", title: "Bad", sourceURL: "file:///tmp/source")])
        expectThrows("non-HTTPS source URLs are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(data(badURL))
        }
        do {
            let localSource = document(version: "1.0", entries: [
                entry(id: "song.local", title: "Local", sourceURL: "http://127.0.0.1:3939/wiki/local")
            ])
            _ = try SongKnowledgeStore.decodeAndValidate(data(localSource))
            checks += 1
        } catch {
            failures.append("127.0.0.1 development source URL was rejected")
        }
        var unknownObject = try! JSONSerialization.jsonObject(with: data(document(version: "1.0", entries: [entry(id: "song.a", title: "A")]))) as! [String: Any]
        unknownObject["unexpected"] = true
        let unknownData = try! JSONSerialization.data(withJSONObject: unknownObject)
        expectThrows("unknown schema fields are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(unknownData)
        }
        expectThrows("oversized documents are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(Data(repeating: 0x20, count: SongKnowledgeStore.maximumDocumentSize + 1))
        }
        expect(
            AIMCPKnowledgeConfiguration.endpoint.absoluteString == AIMCPKnowledgeConfiguration.defaultEndpoint,
            "production AIMCP endpoint is fixed to MikuWiki"
        )
        let productionEndpoint = AIMCPKnowledgeConfiguration.endpoint
        expect(productionEndpoint.scheme == "https", "production AIMCP endpoint requires HTTPS")
        expect(productionEndpoint.host == "mikuwiki.qimake.com", "production AIMCP endpoint host cannot be changed")
        expect(productionEndpoint.path == "/api/v1/song-knowledge", "production AIMCP endpoint path cannot be changed")
        expect(productionEndpoint.port == nil, "production AIMCP endpoint uses the default HTTPS port")
        expect(productionEndpoint.user == nil, "production AIMCP endpoint contains no user info")
        expect(productionEndpoint.password == nil, "production AIMCP endpoint contains no password")
        expect(productionEndpoint.query == nil, "production AIMCP endpoint contains no query secret")
        expect(productionEndpoint.fragment == nil, "production AIMCP endpoint contains no fragment")
        expect(productionEndpoint.standardized.path == productionEndpoint.path, "production AIMCP endpoint path is canonical")
        expect(!productionEndpoint.isFileURL, "production AIMCP endpoint is not a local file URL")

        let storedKey = "aimcp_" + String(repeating: "k", count: 43)
        let replacementKey = "aimcp_" + String(repeating: "r", count: 43)
        let existingKeychain = FakeAIMCPKeychain(item: Data(storedKey.utf8))
        do {
            expect(try AIMCPKnowledgeConfiguration.hasAPIKey(keychain: existingKeychain.store), "an existing classic generic-password item is detected without accessibility attributes")
            let existenceQuery = existingKeychain.copyQueries[0]
            expect(existenceQuery[kSecReturnData as String] == nil, "key existence checks never request secret data")
            expect(existenceQuery[kSecReturnAttributes as String] == nil, "key existence checks do not require accessibility attributes")
            expect(existenceQuery[kSecAttrAccessible as String] == nil, "AIMCP queries do not impose an iOS accessibility class")
            expect(existenceQuery[kSecUseAuthenticationContext as String] == nil, "AIMCP existence checks do not suppress normal macOS authorization prompts")
            expect(existenceQuery[kSecAttrService as String] as? String == AIMCPKnowledgeConfiguration.keychainService, "AIMCP queries keep the existing keychain service")
            expect(existenceQuery[kSecAttrAccount as String] as? String == AIMCPKnowledgeConfiguration.keychainAccount, "AIMCP queries keep the existing keychain account")

            expect(try AIMCPKnowledgeConfiguration.apiKey(keychain: existingKeychain.store) == storedKey, "a classic generic-password item without accessibility attributes can be read")
            let readQuery = existingKeychain.copyQueries[1]
            expect(readQuery[kSecReturnData as String] as? Bool == true, "key reads request only the secret data")
            expect(readQuery[kSecReturnAttributes as String] == nil, "key reads do not require keychain attributes")
            expect(readQuery[kSecUseAuthenticationContext as String] == nil, "key reads allow normal macOS authorization prompts")

            let copiesBeforeUpdate = existingKeychain.copyQueries.count
            try AIMCPKnowledgeConfiguration.save(apiKey: replacementKey, keychain: existingKeychain.store)
            expect(existingKeychain.copyQueries.count == copiesBeforeUpdate, "saving an entered key does not read the previous secret")
            expect(existingKeychain.updateQueries.count == 1 && existingKeychain.addQueries.isEmpty, "saving updates an existing item without replacing its ACL")
            expect(existingKeychain.updateQueries[0].0[kSecAttrAccessible as String] == nil, "updating a key does not replace its existing accessibility or ACL")
            expect(existingKeychain.item == Data(replacementKey.utf8), "a successful keychain update changes the stored key")
        } catch {
            failures.append("classic AIMCP keychain item: \(error)")
        }

        let preservedKeychain = FakeAIMCPKeychain(item: Data(storedKey.utf8))
        do {
            try AIMCPKnowledgeConfiguration.save(apiKey: nil, keychain: preservedKeychain.store)
            expect(preservedKeychain.copyQueries.count == 1, "saving a blank field checks only whether an existing key is present")
            expect(preservedKeychain.copyQueries[0][kSecReturnData as String] == nil, "preserving a saved key never reads its secret data")
            expect(preservedKeychain.updateQueries.isEmpty && preservedKeychain.addQueries.isEmpty, "saving a blank field leaves an existing key untouched")
            expect(preservedKeychain.item == Data(storedKey.utf8), "saving a blank field preserves the existing key")
        } catch {
            failures.append("preserve existing AIMCP key: \(error)")
        }

        let newKeychain = FakeAIMCPKeychain()
        do {
            try AIMCPKnowledgeConfiguration.save(apiKey: storedKey, keychain: newKeychain.store)
            expect(newKeychain.updateQueries.count == 1, "saving first attempts to update the exact generic-password item")
            expect(newKeychain.addQueries.count == 1, "a missing generic-password item is added after update returns item-not-found")
            expect(newKeychain.addQueries[0][kSecAttrAccessible as String] == nil, "new AIMCP items use the classic macOS keychain defaults")
            expect(newKeychain.item == Data(storedKey.utf8), "a successful add stores the new key")
            try AIMCPKnowledgeConfiguration.clearAPIKey(keychain: newKeychain.store)
            expect(newKeychain.deleteQueries.count == 1 && newKeychain.item == nil, "clearing deletes the exact generic-password item")
        } catch {
            failures.append("new AIMCP keychain item: \(error)")
        }

        let copyFailureKeychain = FakeAIMCPKeychain()
        copyFailureKeychain.copyStatus = errSecInteractionNotAllowed
        do {
            _ = try AIMCPKnowledgeConfiguration.hasAPIKey(keychain: copyFailureKeychain.store)
            failures.append("keychain existence failure pretended to succeed")
        } catch AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(let status) where status == errSecInteractionNotAllowed {
            checks += 1
        } catch {
            failures.append("keychain existence failure returned the wrong error: \(error)")
        }

        let updateFailureKeychain = FakeAIMCPKeychain(item: Data(storedKey.utf8))
        updateFailureKeychain.updateStatus = errSecAuthFailed
        do {
            try AIMCPKnowledgeConfiguration.save(apiKey: replacementKey, keychain: updateFailureKeychain.store)
            failures.append("keychain update failure pretended to succeed")
        } catch AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(let status) where status == errSecAuthFailed {
            checks += 1
        } catch {
            failures.append("keychain update failure returned the wrong error: \(error)")
        }
        expect(updateFailureKeychain.item == Data(storedKey.utf8), "a failed update leaves the existing key unchanged")

        let addFailureKeychain = FakeAIMCPKeychain()
        addFailureKeychain.addStatus = errSecNotAvailable
        do {
            try AIMCPKnowledgeConfiguration.save(apiKey: storedKey, keychain: addFailureKeychain.store)
            failures.append("keychain add failure pretended to succeed")
        } catch AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(let status) where status == errSecNotAvailable {
            checks += 1
        } catch {
            failures.append("keychain add failure returned the wrong error: \(error)")
        }
        expect(addFailureKeychain.item == nil, "a failed add does not create a key")

        let deleteFailureKeychain = FakeAIMCPKeychain(item: Data(storedKey.utf8))
        deleteFailureKeychain.deleteStatus = errSecAuthFailed
        do {
            try AIMCPKnowledgeConfiguration.clearAPIKey(keychain: deleteFailureKeychain.store)
            failures.append("keychain delete failure pretended to succeed")
        } catch AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(let status) where status == errSecAuthFailed {
            checks += 1
        } catch {
            failures.append("keychain delete failure returned the wrong error: \(error)")
        }
        expect(deleteFailureKeychain.item == Data(storedKey.utf8), "a failed delete leaves the key intact")

        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtureURL = folder.appendingPathComponent("bundled.json")
        let base = document(version: "1.0", entries: [
            entry(id: "song.alpha", title: "Alpha", content: "base Alpha", featured: true),
            entry(id: "song.melt", title: "Melt", creator: "ryo"),
            entry(id: "song.tell-your-world", title: "Tell Your World", creator: "kz")
        ])
        try! data(base).write(to: fixtureURL)

        let remote = document(version: "2.0", entries: [
            entry(id: "song.alpha", title: "Alpha", content: "remote Alpha", status: .remote),
            entry(id: "song.melt", title: "Melt", content: "remote Melt", status: .remote),
            entry(id: "song.beta", title: "Beta", status: .remote)
        ])
        let fake = FakeKnowledgeDownloader(data: data(remote))
        let store = SongKnowledgeStore(
            applicationSupportDirectory: folder,
            bundledURL: fixtureURL,
            downloader: { request in try await fake.download(request) }
        )

        do {
            expect(await fake.calls == 0, "loading the store does not access the network")
            try await store.setFavorite(true, id: "song.alpha")
            try await store.setFavorite(true, id: "song.melt")
            let customAlpha = document(version: "custom-1", entries: [
                entry(id: "song.alpha", title: "Alpha", content: "custom Alpha", status: .manual)
            ])
            let imported = try await store.importJSON(data(customAlpha))
            expect(imported.importedCount == 1, "manual import reports its count")
            let update = try await store.checkForUpdates()
            expect(update == .init(version: "2.0", entryCount: 3, source: .github), "valid GitHub update succeeds")
            let githubRequest = await fake.requests.first
            expect(githubRequest?.url == SongKnowledgeStore.remoteURL, "no-key updates retain the GitHub endpoint")
            expect(githubRequest?.value(forHTTPHeaderField: "Authorization") == nil, "GitHub never receives an AIMCP key")
            let alpha = await store.entries(matching: "Alpha")
            expect(alpha.first?.content.english == "custom Alpha", "custom entry wins over a downloaded entry with the same ID")
            expect(await store.entries(matching: "Melt").first?.content.english == "remote Melt", "remote entry replaces bundled data with the same ID")
            expect(await store.entries(matching: "Beta").first?.sourceStatus == SongKnowledgeSourceStatus.remote, "new remote entry is available")
            expect(await store.allEntries().count == 3, "a GitHub update remains a complete catalog replacement")
            expect(await store.isFavorite("song.alpha"), "update preserves favorites")
            expect(await store.isFavorite("song.melt"), "update preserves existing favorite state")
            expect((await store.entries(matching: "Tell Your World")).isEmpty, "a GitHub update removes bundled entries absent from its complete snapshot")

            let customReplacement = document(version: "custom-2", entries: [
                entry(id: "song.alpha", title: "Alpha", content: "custom Alpha v2", status: .manual),
                entry(id: "song.gamma", title: "Gamma", status: .manual)
            ])
            let secondImport = try await store.importJSON(data(customReplacement))
            expect(secondImport == .init(importedCount: 2, replacedCustomCount: 1), "import merges and reports replaced custom IDs")
            expect(await store.entries(matching: "Gamma").first?.sourceStatus == SongKnowledgeSourceStatus.manual, "manual source status cannot be forged by imported JSON")

            let beforeFailure = await store.allEntries()
            await fake.set(data: Data("broken".utf8))
            do {
                _ = try await store.checkForUpdates()
                failures.append("damaged update did not throw")
            } catch {}
            checks += 1
            expect(await store.allEntries() == beforeFailure, "damaged update preserves the previous effective data")
            expect(await store.activeVersion() == "2.0", "damaged update preserves the previous version")

            let badImport = document(version: "bad", entries: [
                entry(id: "song.gamma", title: "Gamma", sourceURL: "http://example.com")
            ])
            do {
                _ = try await store.importJSON(data(badImport))
                failures.append("invalid import did not throw")
            } catch {}
            checks += 1
            expect(await store.entries(matching: "Gamma").first?.sourceStatus == SongKnowledgeSourceStatus.manual, "failed import leaves custom data intact")

            let exported = try await store.exportJSON()
            let exportedDocument = try SongKnowledgeStore.decodeAndValidate(exported)
            expect(exportedDocument.entries.contains { $0.id == "song.alpha" && $0.sourceStatus == SongKnowledgeSourceStatus.manual }, "export includes effective custom provenance")
            expect(exportedDocument.entries.contains { $0.id == "song.beta" && $0.sourceStatus == SongKnowledgeSourceStatus.remote }, "export includes effective remote provenance")

            let reloaded = SongKnowledgeStore(applicationSupportDirectory: folder, bundledURL: fixtureURL)
            expect(await reloaded.isFavorite("song.alpha"), "favorites persist in their own small file")
            expect(await reloaded.entries(matching: "Alpha").first?.content.english == "custom Alpha v2", "custom entries persist independently")
        } catch {
            failures.append("update/import flow: \(error)")
        }

        let aimcpURL = URL(string: AIMCPKnowledgeConfiguration.defaultEndpoint)!
        let apiKey = "aimcp_" + String(repeating: "a", count: 43)
        let aimcpFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: aimcpFolder) }
        let aimcpFixtureURL = aimcpFolder.appendingPathComponent("bundled.json")
        try! data(base).write(to: aimcpFixtureURL)
        let aimcpFake = FakeKnowledgeDownloader(data: data(remote))
        let aimcpStore = SongKnowledgeStore(
            applicationSupportDirectory: aimcpFolder,
            bundledURL: aimcpFixtureURL,
            downloader: { request in try await aimcpFake.download(request) },
            apiKeyLoader: { apiKey }
        )
        do {
            let update = try await aimcpStore.checkForUpdates()
            expect(update == .init(version: "2.0", entryCount: 3, source: .aimcp), "a configured key uses AIMCP")
            let request = await aimcpFake.requests.first
            expect(request?.url?.scheme == aimcpURL.scheme && request?.url?.host == aimcpURL.host && request?.url?.path == aimcpURL.path, "AIMCP uses only the configured snapshot endpoint")
            expect(request?.httpMethod == "GET" && request?.httpBody == nil, "AIMCP snapshot sends no request body or chat")
            expect(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "pageSize", value: "250")], "AIMCP query contains only pagination metadata")
            expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)", "AIMCP key is sent only as a bearer header")
        } catch {
            failures.append("AIMCP update flow: \(error)")
        }

        let pagedFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: pagedFolder) }
        let pagedFixtureURL = pagedFolder.appendingPathComponent("bundled.json")
        try! data(base).write(to: pagedFixtureURL)
        let pagedEntries = (0..<1_001).map { index in
            entry(
                id: "song.paged-\(index)",
                title: "Paged \(index)",
                content: "Page content \(index)",
                korean: "한국어 \(index)",
                status: .remote
            )
        }
        let pageSlices = stride(from: 0, to: pagedEntries.count, by: 250).map { start -> Data in
            let end = min(start + 250, pagedEntries.count)
            let hasMore = end < pagedEntries.count
            return pageData(
                version: "r1001",
                entries: Array(pagedEntries[start..<end]),
                total: pagedEntries.count,
                nextCursor: hasMore ? "page-\(end / 250)" : nil,
                truncated: hasMore
            )
        }
        let pagedFake = SequencedKnowledgeDownloader(pages: pageSlices)
        let pagedStore = SongKnowledgeStore(
            applicationSupportDirectory: pagedFolder,
            bundledURL: pagedFixtureURL,
            downloader: { request in try await pagedFake.download(request) },
            apiKeyLoader: { apiKey },
            endpointLoader: { aimcpURL }
        )
        do {
            let result = try await pagedStore.checkForUpdates()
            expect(result == .init(version: "r1001", entryCount: 1_001, source: .aimcp), "AIMCP installs all 1001 paginated entries atomically")
            let requests = await pagedFake.requests
            expect(requests.count == 5, "AIMCP follows every continuation page")
            expect(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "pageSize", value: "250")) == true, "AIMCP explicitly enables pagination")
            expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "cursor", value: "page-1")) == true, "AIMCP sends the returned continuation cursor")
            let korean = await pagedStore.entries(matching: "Paged 1000").first
            expect(korean?.text(for: "ko") == "한국어 1000", "AIMCP preserves Korean song content")

            let cacheURL = pagedFolder
                .appendingPathComponent("MikuDesktop/Knowledge", isDirectory: true)
                .appendingPathComponent("miku-knowledge-aimcp.json")
            let completeCache = try Data(contentsOf: cacheURL)
            let beforeFailure = await pagedStore.allEntries()
            let duplicate = entry(id: "song.partial", title: "Partial", status: .remote)
            let brokenFake = SequencedKnowledgeDownloader(pages: [
                pageData(version: "r2000", entries: [duplicate], total: 2, nextCursor: "duplicate", truncated: true),
                pageData(version: "r2000", entries: [duplicate], total: 2, nextCursor: nil, truncated: false),
            ])
            let brokenStore = SongKnowledgeStore(
                applicationSupportDirectory: pagedFolder,
                bundledURL: pagedFixtureURL,
                downloader: { request in try await brokenFake.download(request) },
                apiKeyLoader: { apiKey },
                endpointLoader: { aimcpURL }
            )
            do {
                _ = try await brokenStore.checkForUpdates()
                failures.append("duplicate paginated AIMCP IDs did not throw")
            } catch {}
            checks += 1
            expect(await brokenStore.allEntries() == beforeFailure, "failed pagination leaves the complete in-memory catalog intact")
            expect(try Data(contentsOf: cacheURL) == completeCache, "failed pagination never overwrites the complete AIMCP cache")

            let loopFake = SequencedKnowledgeDownloader(pages: [
                pageData(version: "r2000", entries: [entry(id: "song.loop-a", title: "Loop A")], total: 2, nextCursor: "same", truncated: true),
                pageData(version: "r2000", entries: [entry(id: "song.loop-b", title: "Loop B")], total: 2, nextCursor: "same", truncated: true),
            ])
            let loopFolder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: loopFolder) }
            let loopStore = SongKnowledgeStore(
                applicationSupportDirectory: loopFolder,
                bundledURL: pagedFixtureURL,
                downloader: { request in try await loopFake.download(request) },
                apiKeyLoader: { apiKey },
                endpointLoader: { aimcpURL }
            )
            do {
                _ = try await loopStore.checkForUpdates()
                failures.append("repeated AIMCP cursor did not throw")
            } catch {}
            checks += 1

            let mixedFake = SequencedKnowledgeDownloader(pages: [
                pageData(version: "r2000", entries: [entry(id: "song.mix-a", title: "Mix A")], total: 2, nextCursor: "next", truncated: true),
                pageData(version: "r2001", entries: [entry(id: "song.mix-b", title: "Mix B")], total: 2, nextCursor: nil, truncated: false),
            ])
            let mixedFolder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: mixedFolder) }
            let mixedStore = SongKnowledgeStore(
                applicationSupportDirectory: mixedFolder,
                bundledURL: pagedFixtureURL,
                downloader: { request in try await mixedFake.download(request) },
                apiKeyLoader: { apiKey },
                endpointLoader: { aimcpURL }
            )
            do {
                _ = try await mixedStore.checkForUpdates()
                failures.append("mixed AIMCP snapshot versions did not throw")
            } catch {}
            checks += 1
        } catch {
            failures.append("AIMCP pagination flow: \(error)")
        }

        let mergeFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: mergeFolder) }
        let wikiEntries = [
            entry(
                id: "song.world-is-mine",
                title: "World is Mine",
                creator: "Wiki ryo",
                sourceURL: "https://mikuwiki.qimake.com/wiki/world-is-mine",
                content: "Wiki World is Mine",
                featured: false,
                status: .remote
            ),
            entry(
                id: "song.tell-your-world",
                title: "Tell Your World",
                creator: "Wiki kz",
                sourceURL: "https://mikuwiki.qimake.com/wiki/tell-your-world",
                content: "Wiki Tell Your World",
                featured: false,
                status: .remote
            ),
            entry(
                id: "song.senbonzakura",
                title: "千本桜",
                creator: "Wiki 黒うさP",
                sourceURL: "https://mikuwiki.qimake.com/wiki/senbonzakura",
                content: "Wiki 千本桜",
                featured: false,
                status: .remote
            )
        ]
        let wikiDocument = document(version: "wiki-merge", entries: wikiEntries)
        let mergeFake = FakeKnowledgeDownloader(data: data(wikiDocument))
        let mergeStore = SongKnowledgeStore(
            applicationSupportDirectory: mergeFolder,
            bundledURL: bundledURL,
            downloader: { request in try await mergeFake.download(request) },
            apiKeyLoader: { apiKey },
            endpointLoader: { aimcpURL }
        )
        do {
            _ = try await mergeStore.checkForUpdates()
            let merged = Dictionary(uniqueKeysWithValues: await mergeStore.allEntries().map { ($0.id, $0) })
            expect(merged["song.world-is-mine"]?.aliases.first == "World is Mine", "AIMCP primary alias comes first")
            expect(merged["song.world-is-mine"]?.aliases.contains("WorldIsMine") == true, "AIMCP merge preserves WorldIsMine")
            expect(merged["song.world-is-mine"]?.aliases.contains("世界第一的公主殿下") == true, "AIMCP merge preserves the Traditional Chinese World is Mine alias")
            expect(merged["song.tell-your-world"]?.aliases == ["Tell Your World", "TellYourWorld"], "AIMCP merge preserves TellYourWorld with ordered deduplication")
            expect(merged["song.senbonzakura"]?.aliases.prefix(2) == ["千本桜", "千本櫻"], "AIMCP merge preserves 千本櫻 after the remote primary alias")
            expect(merged["song.world-is-mine"]?.featured == true, "AIMCP cannot clear a bundled featured flag")
            expect(merged["song.tell-your-world"]?.featured == true, "AIMCP preserves Tell Your World's featured flag")
            expect(merged["song.senbonzakura"]?.featured == true, "AIMCP preserves 千本桜's featured flag")
            expect(merged["song.world-is-mine"]?.content.english == "Wiki World is Mine", "AIMCP content wins during metadata merge")
            expect(merged["song.world-is-mine"]?.creators == ["Wiki ryo"], "AIMCP creators win during metadata merge")
            expect(merged["song.world-is-mine"]?.sourceURL == "https://mikuwiki.qimake.com/wiki/world-is-mine", "AIMCP source URL wins during metadata merge")
            expect(merged["song.world-is-mine"]?.kind == wikiEntries[0].kind, "AIMCP kind wins during metadata merge")
            expect(merged["song.world-is-mine"]?.sourceStatus == .remote, "AIMCP provenance wins during metadata merge")
            expect((await mergeStore.entries(matching: "WorldIsMine")).first?.id == "song.world-is-mine", "preserved WorldIsMine remains searchable")
            expect((await mergeStore.entries(matching: "世界第一的公主殿下")).first?.id == "song.world-is-mine", "preserved Chinese alias remains searchable")
            expect((await mergeStore.entries(matching: "TellYourWorld")).first?.id == "song.tell-your-world", "preserved TellYourWorld remains searchable")
            expect((await mergeStore.entries(matching: "千本櫻")).first?.id == "song.senbonzakura", "preserved 千本櫻 remains searchable")
            let mergedFeatured = Set(await mergeStore.featuredEntries().map(\.id))
            expect(
                mergedFeatured.isSuperset(of: ["song.world-is-mine", "song.tell-your-world", "song.senbonzakura"]),
                "AIMCP metadata updates preserve all three bundled featured songs"
            )

            let customWorld = document(version: "custom-world", entries: [
                entry(id: "song.world-is-mine", title: "Custom World", content: "custom only", status: .manual)
            ])
            _ = try await mergeStore.importJSON(data(customWorld))
            let custom = await mergeStore.allEntries().first { $0.id == "song.world-is-mine" }
            expect(custom?.aliases == ["Custom World"], "custom entries completely replace merged aliases")
            expect(custom?.featured == false, "custom entries completely replace the merged featured flag")
            expect(custom?.content.english == "custom only", "custom entries completely replace merged metadata")
        } catch {
            failures.append("AIMCP metadata merge: \(error)")
        }

        let blockedUpdateFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: blockedUpdateFolder) }
        let blockedUpdateFixture = blockedUpdateFolder.appendingPathComponent("bundled.json")
        try! data(base).write(to: blockedUpdateFixture)
        let blockedAIMCPURL = blockedUpdateFolder
            .appendingPathComponent("MikuDesktop/Knowledge", isDirectory: true)
            .appendingPathComponent("miku-knowledge-aimcp.json", isDirectory: true)
        try! FileManager.default.createDirectory(at: blockedAIMCPURL, withIntermediateDirectories: true)
        let blockedUpdateFake = FakeKnowledgeDownloader(data: data(remote))
        let blockedUpdateStore = SongKnowledgeStore(
            applicationSupportDirectory: blockedUpdateFolder,
            bundledURL: blockedUpdateFixture,
            downloader: { request in try await blockedUpdateFake.download(request) },
            apiKeyLoader: { apiKey },
            endpointLoader: { aimcpURL }
        )
        let beforeBlockedUpdate = await blockedUpdateStore.allEntries()
        do {
            _ = try await blockedUpdateStore.checkForUpdates()
            failures.append("unwritable AIMCP cache did not throw")
        } catch {}
        checks += 1
        expect(await blockedUpdateStore.allEntries() == beforeBlockedUpdate, "failed AIMCP cache persistence leaves in-memory knowledge unchanged")

        let aliasExportFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: aliasExportFolder) }
        let aliasExportFixture = aliasExportFolder.appendingPathComponent("bundled.json")
        let baseAliases = (0..<24).map { "Base Alias \($0)" }
        let remoteAliases = (0..<24).map { "Remote Alias \($0)" }
        let aliasBase = document(version: "alias-base", entries: [
            entry(id: "song.alias-limit", title: baseAliases[0], aliases: baseAliases)
        ])
        let aliasRemote = document(version: "alias-remote", entries: [
            entry(id: "song.alias-limit", title: remoteAliases[0], aliases: remoteAliases, status: .remote)
        ])
        try! data(aliasBase).write(to: aliasExportFixture)
        let aliasExportFake = FakeKnowledgeDownloader(data: data(aliasRemote))
        let aliasExportStore = SongKnowledgeStore(
            applicationSupportDirectory: aliasExportFolder,
            bundledURL: aliasExportFixture,
            downloader: { request in try await aliasExportFake.download(request) },
            apiKeyLoader: { apiKey },
            endpointLoader: { aimcpURL }
        )
        do {
            _ = try await aliasExportStore.checkForUpdates()
            let mergedAliasEntry = await aliasExportStore.allEntries().first { $0.id == "song.alias-limit" }
            expect(mergedAliasEntry?.aliases.count == 48, "valid source aliases remain intact after merging")
            do {
                _ = try await aliasExportStore.exportJSON()
                failures.append("merged aliases beyond the schema limit were exported")
            } catch SongKnowledgeError.invalidSchema {
                checks += 1
            } catch {
                failures.append("merged aliases returned the wrong export error: \(error)")
            }
        } catch {
            failures.append("merged alias export boundary: \(error)")
        }

        let catalogExportFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: catalogExportFolder) }
        let catalogExportFixture = catalogExportFolder.appendingPathComponent("bundled.json")
        let catalogBase = document(version: "catalog-base", entries: (0..<501).map {
            entry(id: "song.base-\($0)", title: "Base \($0)")
        })
        let catalogRemote = document(version: "catalog-remote", entries: (0..<501).map {
            entry(id: "song.remote-\($0)", title: "Remote \($0)", status: .remote)
        })
        try! data(catalogBase).write(to: catalogExportFixture)
        let catalogExportFake = FakeKnowledgeDownloader(data: data(catalogRemote))
        let catalogExportStore = SongKnowledgeStore(
            applicationSupportDirectory: catalogExportFolder,
            bundledURL: catalogExportFixture,
            downloader: { request in try await catalogExportFake.download(request) },
            apiKeyLoader: { apiKey },
            endpointLoader: { aimcpURL }
        )
        do {
            _ = try await catalogExportStore.checkForUpdates()
            expect(await catalogExportStore.allEntries().count == 1_002, "valid source catalogs remain intact after union")
            do {
                _ = try await catalogExportStore.exportJSON()
                failures.append("merged catalog beyond the schema limit was exported")
            } catch SongKnowledgeError.invalidSchema {
                checks += 1
            } catch {
                failures.append("merged catalog returned the wrong export error: \(error)")
            }
        } catch {
            failures.append("merged catalog export boundary: \(error)")
        }

        for status in [401, 403, 429] {
            let statusFolder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: statusFolder) }
            let fixture = statusFolder.appendingPathComponent("bundled.json")
            try! data(base).write(to: fixture)
            let fake = FakeKnowledgeDownloader(data: Data(), status: status)
            let store = SongKnowledgeStore(
                applicationSupportDirectory: statusFolder,
                bundledURL: fixture,
                downloader: { request in try await fake.download(request) },
                apiKeyLoader: { apiKey },
                endpointLoader: { aimcpURL }
            )
            let before = await store.allEntries()
            do {
                _ = try await store.checkForUpdates()
                failures.append("AIMCP HTTP \(status) did not throw")
            } catch SongKnowledgeError.httpStatus(let actual) where actual == status {
                checks += 1
            } catch {
                failures.append("AIMCP HTTP \(status) returned the wrong error: \(error)")
            }
            expect(await fake.calls == 1, "AIMCP HTTP \(status) does not silently fall back")
            expect(await store.allEntries() == before, "AIMCP HTTP \(status) leaves existing knowledge available")
        }

        for failure in [RoutedKnowledgeDownloader.AIMCPFailure.offline, .status(503)] {
            let fallbackFolder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: fallbackFolder) }
            let fixture = fallbackFolder.appendingPathComponent("bundled.json")
            try! data(base).write(to: fixture)
            let aimcpOnly = entry(
                id: "song.aimcp-only",
                title: "AIMCP Only",
                creator: "MikuWiki",
                sourceURL: "https://mikuwiki.qimake.com/wiki/aimcp-only",
                status: .remote
            )
            let initialAIMCP = FakeKnowledgeDownloader(data: data(document(version: "wiki-only", entries: [aimcpOnly])))
            let initialStore = SongKnowledgeStore(
                applicationSupportDirectory: fallbackFolder,
                bundledURL: fixture,
                downloader: { request in try await initialAIMCP.download(request) },
                apiKeyLoader: { apiKey },
                endpointLoader: { aimcpURL }
            )
            do {
                let initialResult = try await initialStore.checkForUpdates()
                expect(initialResult.source == .aimcp, "AIMCP-only setup installs through AIMCP")
                expect(await initialStore.activeVersion() == "wiki-only", "AIMCP cache version is active after installation")
                try await initialStore.setFavorite(true, id: aimcpOnly.id)
                let cacheFolder = fallbackFolder.appendingPathComponent("MikuDesktop/Knowledge", isDirectory: true)
                let aimcpCacheURL = cacheFolder.appendingPathComponent("miku-knowledge-aimcp.json")
                let githubCacheURL = cacheFolder.appendingPathComponent("miku-knowledge-updated.json")
                let aimcpCacheBeforeFallback = try Data(contentsOf: aimcpCacheURL)
                expect(!FileManager.default.fileExists(atPath: githubCacheURL.path), "successful AIMCP update does not overwrite the GitHub cache")

                let fake = RoutedKnowledgeDownloader(aimcpURL: aimcpURL, githubData: data(remote), aimcpFailure: failure)
                let store = SongKnowledgeStore(
                    applicationSupportDirectory: fallbackFolder,
                    bundledURL: fixture,
                    downloader: { request in try await fake.download(request) },
                    apiKeyLoader: { apiKey },
                    endpointLoader: { aimcpURL }
                )
                expect((await store.entries(matching: "AIMCP Only")).first?.id == aimcpOnly.id, "AIMCP-only entry survives an app restart before fallback")
                expect(await store.isFavorite(aimcpOnly.id), "AIMCP-only favorite survives an app restart before fallback")
                let result = try await store.checkForUpdates()
                expect(result.source == .githubFallback, "unavailable AIMCP is explicitly reported as a GitHub fallback")
                let requests = await fake.requests
                expect(requests.count == 2 && requests.first?.url?.path == aimcpURL.path && requests.last?.url == SongKnowledgeStore.remoteURL, "fallback tries AIMCP before GitHub")
                expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)", "AIMCP request carries its bearer key")
                expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil, "fallback never forwards the key to GitHub")
                expect(await store.entries(matching: "Beta").first?.id == "song.beta", "fallback installs the validated GitHub document")
                expect((await store.entries(matching: "AIMCP Only")).first?.id == aimcpOnly.id, "fallback preserves an AIMCP-only entry")
                expect(await store.isFavorite(aimcpOnly.id), "fallback preserves an AIMCP-only favorite")
                expect(await store.activeVersion() == "wiki-only", "fallback keeps the AIMCP overlay version active")
                let exported = try SongKnowledgeStore.decodeAndValidate(await store.exportJSON())
                expect(exported.version == "wiki-only", "export uses the active AIMCP overlay version")
                expect(try Data(contentsOf: aimcpCacheURL) == aimcpCacheBeforeFallback, "fallback leaves the AIMCP cache unchanged")
                let githubCache = try SongKnowledgeStore.decodeAndValidate(Data(contentsOf: githubCacheURL))
                expect(githubCache.version == remote.version, "fallback writes the GitHub snapshot only to the GitHub cache")

                let restarted = SongKnowledgeStore(applicationSupportDirectory: fallbackFolder, bundledURL: fixture)
                expect((await restarted.entries(matching: "AIMCP Only")).first?.id == aimcpOnly.id, "AIMCP-only entry survives fallback and restart")
                expect(await restarted.isFavorite(aimcpOnly.id), "AIMCP-only favorite survives fallback and restart")
                expect(await restarted.activeVersion() == "wiki-only", "restart restores the AIMCP overlay version")
            } catch {
                failures.append("GitHub fallback flow: \(error)")
            }
        }

        let rollbackFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: rollbackFolder) }
        let rollbackFixtureURL = rollbackFolder.appendingPathComponent("bundled.json")
        try! data(base).write(to: rollbackFixtureURL)
        let rollbackStore = SongKnowledgeStore(applicationSupportDirectory: rollbackFolder, bundledURL: rollbackFixtureURL)
        let blockedPreferencesURL = rollbackFolder
            .appendingPathComponent("MikuDesktop/Knowledge", isDirectory: true)
            .appendingPathComponent("song-preferences.json", isDirectory: true)
        try! FileManager.default.createDirectory(at: blockedPreferencesURL, withIntermediateDirectories: true)
        do {
            try await rollbackStore.setFavorite(true, id: "song.alpha")
            failures.append("unwritable favorite did not throw")
        } catch {}
        checks += 1
        expect(!(await rollbackStore.isFavorite("song.alpha")), "failed favorite persistence restores the in-memory value")

        let preferenceFolder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: preferenceFolder) }
        let preferenceURL = preferenceFolder.appendingPathComponent("bundled.json")
        try! data(base).write(to: preferenceURL)
        let preferenceStore = SongKnowledgeStore(applicationSupportDirectory: preferenceFolder, bundledURL: preferenceURL)
        do {
            let mention = try await preferenceStore.recordExplicitPreference(in: "Who made Tell Your World?")
            expect(mention == nil, "mentioning a song does not create a preference")
            let direct = try await preferenceStore.recordExplicitPreference(in: "我真的很喜歡 Melt")
            expect(direct?.id == "song.melt", "an explicit and reliable direct preference is recorded")
            let ambiguous = try await preferenceStore.recordExplicitPreference(in: "I love Melt and Tell Your World")
            expect(ambiguous == nil, "an ambiguous multi-song preference is not guessed")
            let question = try await preferenceStore.recordExplicitPreference(in: "Do you like Tell Your World?")
            expect(question == nil, "a question to Miku is not a user preference")
            let negative = try await preferenceStore.recordExplicitPreference(in: "I don't like Tell Your World")
            expect(negative == nil, "a negative statement is not stored as a favorite")
            let chineseNegative = try await preferenceStore.recordExplicitPreference(in: "Melt 不是我喜歡的歌")
            expect(chineseNegative == nil, "a Chinese negative preference is not stored")
            let chineseQuestion = try await preferenceStore.recordExplicitPreference(in: "我只是問你喜歡 Tell Your World 嗎")
            expect(chineseQuestion == nil, "asking Miku whether she likes a song is not stored")
            for text in ["Is Tell Your World your favorite song?", "我朋友很喜歡 Tell Your World", "這首 Tell Your World 是你的最愛"] {
                let otherPreference = try await preferenceStore.recordExplicitPreference(in: text)
                expect(otherPreference == nil, "someone else's preference is not stored: \(text)")
            }
            let pronoun = try await preferenceStore.recordExplicitPreference(
                in: "I really love this song.",
                previousUserMessages: ["Tell me about Tell Your World"]
            )
            expect(pronoun?.id == "song.tell-your-world", "a clear pronoun continues the previous single-song context")
            let favorite = try await preferenceStore.recordExplicitPreference(in: "Tell Your World is my favorite song")
            expect(favorite?.id == "song.tell-your-world", "a first-person favorite is recorded")
            let favorites = await preferenceStore.favoriteEntries().map(\.id)
            expect(Set(favorites) == ["song.melt", "song.tell-your-world"], "only explicit reliable preferences are stored")
        } catch {
            failures.append("preference flow: \(error)")
        }

        await VocaDBChecks.run { expect($0, $1) }

        if failures.isEmpty {
            print("song knowledge: \(checks) checks passed")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("FAILED: \(failures.count) of \(checks) checks\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
