import Foundation

private actor FakeKnowledgeDownloader {
    enum Failure: Error { case offline }

    var data: Data
    var status: Int
    var responseURL: URL
    var shouldFail = false
    private(set) var calls = 0

    init(data: Data, status: Int = 200, responseURL: URL = SongKnowledgeStore.remoteURL) {
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

    func download(_ url: URL) throws -> (Data, URLResponse) {
        calls += 1
        if shouldFail { throw Failure.offline }
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
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
        creator: String = "Verified Creator",
        sourceURL: String = "https://example.com/source",
        content: String? = nil,
        featured: Bool = false,
        status: SongKnowledgeSourceStatus = .bundled
    ) -> SongKnowledgeEntry {
        let value = content ?? "\(title) — \(creator)."
        return SongKnowledgeEntry(
            id: id,
            aliases: [title],
            creators: [creator],
            kind: .song,
            content: SongKnowledgeText(traditionalChinese: value, english: value, japanese: value),
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
            expect(bundled.entries.count == 17, "bundled knowledge contains the verified song, character, and performance entries")
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
        var unknownObject = try! JSONSerialization.jsonObject(with: data(document(version: "1.0", entries: [entry(id: "song.a", title: "A")]))) as! [String: Any]
        unknownObject["unexpected"] = true
        let unknownData = try! JSONSerialization.data(withJSONObject: unknownObject)
        expectThrows("unknown schema fields are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(unknownData)
        }
        expectThrows("oversized documents are rejected") {
            _ = try SongKnowledgeStore.decodeAndValidate(Data(repeating: 0x20, count: SongKnowledgeStore.maximumDocumentSize + 1))
        }

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
            entry(id: "song.beta", title: "Beta", status: .remote)
        ])
        let fake = FakeKnowledgeDownloader(data: data(remote))
        let store = SongKnowledgeStore(
            applicationSupportDirectory: folder,
            bundledURL: fixtureURL,
            downloader: { url in try await fake.download(url) }
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
            expect(update == .init(version: "2.0", entryCount: 2), "valid manual update succeeds")
            let alpha = await store.entries(matching: "Alpha")
            expect(alpha.first?.content.english == "custom Alpha", "custom entry wins over a downloaded entry with the same ID")
            expect(await store.entries(matching: "Beta").first?.sourceStatus == SongKnowledgeSourceStatus.remote, "new remote entry is available")
            expect(await store.isFavorite("song.alpha"), "update preserves favorites")
            expect(await store.isFavorite("song.melt"), "update preserves a favorite even when the new catalog omits its entry")
            expect(await store.entries(matching: "Melt").isEmpty, "a downloaded catalog replaces stale bundled facts instead of merging them back")

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

        if failures.isEmpty {
            print("song knowledge: \(checks) checks passed")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("FAILED: \(failures.count) of \(checks) checks\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
