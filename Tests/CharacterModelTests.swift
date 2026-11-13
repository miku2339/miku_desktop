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

        let v4x = temporary.appendingPathComponent("CharacterModels/tda-v4x")
        let bundledV4X = root.appendingPathComponent("assets/companion-model/tda-v4x")
        let custom = temporary.appendingPathComponent("CharacterModels/custom")
        let withV4X = StaticHTTPServer(rootURL: root, importedModelURL: destination, importedV4XModelURL: v4x, customModelURL: custom)
        let v4xRoute = "/assets/companion-model/tda-v4x"
        try expect(server.safeFileURL(for: v4xRoute + "/miku.pmx") == nil, "V4X is absent without an installed or bundled model")
        for name in CharacterModelStore.v4xRenderFiles {
            let url = bundledV4X.appendingPathComponent(name)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bundled V4X".utf8).write(to: url)
        }
        try expect(withV4X.safeFileURL(for: v4xRoute + "/miku.pmx") == bundledV4X.appendingPathComponent("miku.pmx"), "Bundled V4X has an explicit mount")
        try files.copyItem(at: bundledV4X, to: v4x)
        try expect(withV4X.safeFileURL(for: "/assets/companion-model/tda/miku.pmx") == existing, "V4X leaves the legacy import available")
        try expect(withV4X.safeFileURL(for: "/assets/companion-model/tda-v4x/miku.pmx") == v4x.appendingPathComponent("miku.pmx"), "V4X uses a separate mount")
        try expect(withV4X.safeFileURL(for: "/assets/companion-model/tda-v4x/tex/face_Mikuv4x.tga") == v4x.appendingPathComponent("tex/face_Mikuv4x.tga"), "V4X keeps its texture paths")
        try expect(withV4X.safeFileURL(for: "/assets/companion-model/tda-v4x/よんでね.txt") == nil, "V4X author documents stay on disk")
        try Data().write(to: v4x.appendingPathComponent("tex/unrelated.tga"))
        try expect(withV4X.safeFileURL(for: v4xRoute + "/tex/unrelated.tga") == nil, "V4X serves only its model textures")
        try files.removeItem(at: v4x.appendingPathComponent("tex/face_Mikuv4x.tga"))
        try expect(withV4X.safeFileURL(for: v4xRoute + "/miku.pmx") == bundledV4X.appendingPathComponent("miku.pmx"), "Incomplete local V4X falls back to a complete bundle")

        try expect(CharacterModelStore.resolveSelection(nil, available: [.v4x, .animasa], isExistingUser: false) == .v4x, "A fresh Release starts with V4X")
        try expect(CharacterModelStore.resolveSelection(nil, available: [.v4x, .animasa], isExistingUser: true) == .animasa, "A prior Animasa user stays on Animasa")
        try expect(CharacterModelStore.resolveSelection(nil, available: [.v4x, .classic, .animasa], isExistingUser: false) == .classic, "An existing import takes priority")
        try expect(CharacterModelStore.resolveSelection("tda-v4x", available: [.v4x, .classic, .animasa], isExistingUser: true) == .v4x, "An explicit V4X selection is retained")
        try expect(CharacterModelStore.resolveSelection("animasa", available: [.v4x, .classic, .animasa], isExistingUser: true) == .animasa, "An explicit Animasa selection is retained")
        try expect(CharacterModelStore.resolveSelection("custom", available: [.v4x, .custom, .animasa], isExistingUser: true) == .custom, "An explicit custom selection is retained")

        let source = temporary.appendingPathComponent("user model")
        let textures = source.appendingPathComponent("tex")
        try files.createDirectory(at: textures, withIntermediateDirectories: true)
        let userPMX = source.appendingPathComponent("Custom.pmx")
        let userTexture = textures.appendingPathComponent("face test.png")
        try sentinel.write(to: userTexture)
        try sentinel.write(to: textures.appendingPathComponent("unreferenced.png"))
        let customData = fixturePMX(textures: ["tex\\face test.png"])
        try customData.write(to: userPMX)
        try CharacterModelStore.importCustomModel(from: userPMX, destination: custom)
        let customPMX = custom.appendingPathComponent("miku.pmx")
        let customRoute = "/assets/companion-model/custom"
        try expect(withV4X.safeFileURL(for: customRoute + "/miku.pmx") == customPMX, "The custom slot exposes the selected PMX")
        try expect(withV4X.safeFileURL(for: customRoute + "/tex/face test.png") == custom.appendingPathComponent("tex/face test.png"), "The custom slot preserves a referenced texture's path")
        try expect(withV4X.safeFileURL(for: customRoute + "/tex/unreferenced.png") == nil, "Unreferenced images are not copied")
        try files.createSymbolicLink(at: custom.appendingPathComponent("escape.png"), withDestinationURL: userTexture)
        try expect(withV4X.safeFileURL(for: customRoute + "/escape.png") == nil, "Custom textures cannot link outside the slot")
        for badPath in ["../other.png", "https://host/texture.png", "tex/missing.png"] {
            try fixturePMX(textures: [badPath]).write(to: userPMX)
            do {
                try CharacterModelStore.importCustomModel(from: userPMX, destination: custom)
                fatalError("Invalid texture reference accepted")
            } catch {
                try expect(Data(contentsOf: customPMX) == customData, "Rejected imports preserve the previous custom model")
            }
        }

        for path in CommandLine.arguments.dropFirst() {
            let archive = URL(fileURLWithPath: path)
            let importTarget = temporary.appendingPathComponent("archive-test/model")
            let imported = try CharacterModelStore.importArchive(from: archive, destination: importTarget)
            if imported == .v4x {
                try expect(CharacterModelStore.hasModel(.v4x, in: importTarget), "Original V4X ZIP installs a complete model")
                try expect(try Data(contentsOf: importTarget.appendingPathComponent("miku.pmx")).prefix(4) == Data("PMX ".utf8), "V4X retains the original PMX payload")
                for name in ["AL注意点.jpg", "readme_English.txt", "よんでね.txt"] {
                    try expect(files.fileExists(atPath: importTarget.appendingPathComponent(name).path), "V4X author notices are retained")
                }
                try CharacterModelStore.importCustomModel(from: importTarget.appendingPathComponent("miku.pmx"), destination: custom)
                try expect(CharacterModelStore.hasModel(.custom, in: custom), "Custom import accepts a full PMX with real vertex and texture records")
                continue
            }
            try CharacterModelStore.importArchive(from: archive, destination: destination)
            try expect(Data(contentsOf: existing).prefix(4) == Data("PMX ".utf8), "Original ZIP installs a valid PMX")
            for name in ["ReadMe_Tda.txt", "ReadMe_Tda_English.txt", "ReadMe_金子卵黄.txt", "k_face_MikuAp.tga"] {
                try expect(files.fileExists(atPath: destination.appendingPathComponent(name).path), "Author notices and textures are retained")
            }
            try expect(try files.contentsOfDirectory(atPath: destination.path).count == 19, "Only original model assets are installed")
            try CharacterModelStore.importArchive(from: archive, destination: destination)
            try expect(Set(try files.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) == ["tda", "tda-v4x", "custom"], "Repeated imports leave no staging or duplicate model folders")
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

    private static func fixturePMX(textures: [String]) -> Data {
        var data = Data("PMX ".utf8)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(Float(2).bitPattern)
        data.append(contentsOf: [8, 1, 0, 1, 1, 1, 1, 1, 1])
        for _ in 0..<6 { word(0) }
        word(UInt32(textures.count))
        for texture in textures {
            word(UInt32(texture.utf8.count))
            data.append(contentsOf: texture.utf8)
        }
        return data
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "CharacterModelTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
}
