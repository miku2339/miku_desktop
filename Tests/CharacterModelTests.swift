import Foundation

@main
struct CharacterModelTests {
    private static var checks = 0

    static func main() async throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("miku-model-tests-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("CharacterModels/tda")
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("miku.pmx")
        let sentinel = Data("existing model".utf8)
        try sentinel.write(to: existing)
        let invalid = temporary.appendingPathComponent("wrong.zip")
        try Data("not the original archive".utf8).write(to: invalid)
        do {
            try CharacterModelStore.importArchive(from: invalid, destination: destination)
            fatalError("Invalid archive was accepted")
        } catch CharacterModelStore.ImportError.invalidArchive {
            checks += 1
        }
        try expect(Data(contentsOf: existing) == sentinel, "Rejected imports preserve the active model")

        let root = temporary.appendingPathComponent("Wallpaper")
        let bundled = root.appendingPathComponent("assets/companion-model/tda")
        try files.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("bundled".utf8).write(to: bundled.appendingPathComponent("miku.pmx"))
        let page = root.appendingPathComponent("companion")
        try files.createDirectory(at: page, withIntermediateDirectories: true)
        try Data("public scene".utf8).write(to: page.appendingPathComponent("index.html"))
        let server = StaticHTTPServer(rootURL: root, importedModelURL: destination)
        try expect(server.safeFileURL(for: "/assets/companion-model/tda/miku.pmx") == existing, "Imported model overrides bundled assets")
        try expect(server.safeFileURL(for: "/companion/index.html") == page.appendingPathComponent("index.html"), "Scene resources keep their original root")
        try expect(server.safeFileURL(for: "/assets/companion-model/tda/../../private.txt") == nil, "Parent traversal is rejected")
        try files.createSymbolicLink(at: destination.appendingPathComponent("escape"), withDestinationURL: temporary)
        try expect(server.safeFileURL(for: "/assets/companion-model/tda/escape/wrong.zip") == nil, "Imported assets cannot expose outside files through symlinks")
        let absent = StaticHTTPServer(rootURL: root, importedModelURL: temporary.appendingPathComponent("missing"))
        try expect(absent.safeFileURL(for: "/assets/companion-model/tda/miku.pmx") == bundled.appendingPathComponent("miku.pmx"), "A missing import preserves bundled model selection")

        if CommandLine.arguments.count > 1 {
            let archive = URL(fileURLWithPath: CommandLine.arguments[1])
            try CharacterModelStore.importArchive(from: archive, destination: destination)
            try expect(Data(contentsOf: existing).prefix(4) == Data("PMX ".utf8), "Original ZIP installs a valid PMX")
            for name in ["ReadMe_Tda.txt", "ReadMe_Tda_English.txt", "ReadMe_金子卵黄.txt", "k_face_MikuAp.tga"] {
                try expect(files.fileExists(atPath: destination.appendingPathComponent(name).path), "Author notices and textures are retained")
            }
            try expect(try files.contentsOfDirectory(atPath: destination.path).count == 19, "Only original model assets are installed")
            try CharacterModelStore.importArchive(from: archive, destination: destination)
            try expect(try files.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["tda"], "Repeated imports leave no staging or duplicate model folders")
        }

        let url: URL = try await withCheckedThrowingContinuation { continuation in
            server.start { continuation.resume(with: $0) }
        }
        defer { server.stop() }
        let modelURL = URL(string: "/assets/companion-model/tda/miku.pmx", relativeTo: url)!.absoluteURL
        let (data, response) = try await URLSession.shared.data(from: modelURL)
        try expect((response as? HTTPURLResponse)?.statusCode == 200, "Public model route serves imported data")
        try expect(data == Data(contentsOf: existing), "The renderer receives the imported model bytes")
        var request = URLRequest(url: modelURL)
        request.httpMethod = "HEAD"
        let (headData, headResponse) = try await URLSession.shared.data(for: request)
        try expect((headResponse as? HTTPURLResponse)?.statusCode == 200 && headData.isEmpty, "Model availability HEAD requests work")
        print("CharacterModel: \(checks) checks passed")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "CharacterModelTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
}
