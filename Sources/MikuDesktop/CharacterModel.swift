import CryptoKit
import Foundation

extension Notification.Name {
    static let mikuCharacterModelChanged = Notification.Name("mikuCharacterModelChanged")
}

enum CharacterModelStore {
    enum Model: String, CaseIterable {
        case v4x = "tda-v4x"
        case classic = "tda"
        case custom
        case animasa

        var name: String {
            switch self {
            case .v4x: return "Tda式初音ミクV4X Ver1.00"
            case .classic: return "Tda / 金子卵黄 v1.1"
            case .custom: return "PMX"
            case .animasa: return "Animasa"
            }
        }
    }

    enum ImportError: Error {
        case invalidArchive
        case invalidContents
        case extractionFailed
    }

    static let authorURL = URL(string: "https://bowlroll.net/file/16344")!
    static let v4xAuthorURL = URL(string: "https://bowlroll.net/file/146088")!
    static let selectionKey = "selectedCharacterModel"
    private static let originalSHA256 = "79baabda41248efe06a3e401ae137f34ce8a20b73db6f76c9039ff9c6b673f92"
    private static let v4xSHA256 = "c7036712a1168a1558f61c1256a61c94574878451e02e8a0b6fb8ef945c6bfba"
    private static let importLock = NSLock()
    private static let requiredFiles: Set<String> = [
        "miku.pmx", "body00_s.bmp", "body01_s.bmp", "body02_MikuAp.tga", "hair_MikuAp.png", "hair_s.bmp",
        "k_Asi2.png", "k_face_MikuAp.tga", "k_Hada.png", "k_hika.png", "k_huku1.png", "k_huku2.png",
        "skin_s.bmp", "toon_defo.bmp", "toon_hair.bmp", "toon_skin.bmp",
        "ReadMe_Tda.txt", "ReadMe_Tda_English.txt", "ReadMe_金子卵黄.txt"
    ]
    static let v4xRenderFiles: Set<String> = [
        "miku.pmx", "tex/body00_s.bmp", "tex/body01_s.bmp", "tex/body02_MikuAp.tga", "tex/face_Mikuv4x.tga",
        "tex/hair_Mikuv4x.tga", "tex/hair_s.bmp", "tex/mikuv4x_body00.tga", "tex/skin_s.bmp",
        "tex/toon_defo.bmp", "tex/toon_hair.bmp", "tex/toon_skin.bmp"
    ]
    static let textureExtensions: Set<String> = ["bmp", "gif", "jpeg", "jpg", "png", "spa", "sph", "tga", "webp"]

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MikuDesktop/CharacterModels/tda", isDirectory: true)
    }

    static func importedDirectory(for model: Model, models: URL = directory.deletingLastPathComponent()) -> URL {
        models.appendingPathComponent(model.rawValue, isDirectory: true)
    }

    static func bundledDirectory(for model: Model, wallpaper: URL?) -> URL? {
        wallpaper?.appendingPathComponent("assets/companion-model/\(model.rawValue)", isDirectory: true)
    }

    static func hasModel(_ model: Model, in root: URL?) -> Bool {
        guard let root, isDirectory(root) else { return false }
        if model == .v4x, !isDirectory(root.appendingPathComponent("tex")) { return false }
        let names = model == .v4x ? v4xRenderFiles : ["miku.pmx"]
        return names.allSatisfy { name in
            let values = try? root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink == false
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink == false
    }

    static func availableModels(wallpaper: URL? = Bundle.main.resourceURL?.appendingPathComponent("Wallpaper"),
                                models: URL = directory.deletingLastPathComponent()) -> [Model] {
        Model.allCases.filter { model in
            model == .animasa || hasModel(model, in: importedDirectory(for: model, models: models))
                || hasModel(model, in: bundledDirectory(for: model, wallpaper: wallpaper))
        }
    }

    static func resolveSelection(_ stored: String?, available: [Model], isExistingUser: Bool) -> Model {
        if let stored, let model = Model(rawValue: stored), available.contains(model) { return model }
        if available.contains(.classic) { return .classic }
        return stored == nil && !isExistingUser && available.contains(.v4x) ? .v4x : .animasa
    }

    static var currentModel: Model {
        resolveSelection(UserDefaults.standard.string(forKey: selectionKey), available: availableModels(),
                         isExistingUser: hasExistingUserData)
    }

    private static var hasExistingUserData: Bool {
        let support = directory.deletingLastPathComponent().deletingLastPathComponent()
        return ["memory.json", "events.json", "diagnostics.log"].contains {
            FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path)
        }
    }

    static func initializeSelection() {
        guard UserDefaults.standard.object(forKey: selectionKey) == nil else { return }
        UserDefaults.standard.set(currentModel.rawValue, forKey: selectionKey)
    }

    static func select(_ model: Model) {
        guard availableModels().contains(model) else { return }
        UserDefaults.standard.set(model.rawValue, forKey: selectionKey)
        NotificationCenter.default.post(name: .mikuCharacterModelChanged, object: nil)
    }

    @discardableResult
    static func importArchive(from archive: URL, destination: URL? = nil) throws -> Model {
        importLock.lock()
        defer { importLock.unlock() }
        let files = FileManager.default
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 12 * 1_024 * 1_024 else { throw ImportError.invalidArchive }
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model: Model
        switch digest {
        case originalSHA256: model = .classic
        case v4xSHA256: model = .v4x
        default: throw ImportError.invalidArchive
        }

        let destination = destination ?? importedDirectory(for: model)
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".tda-import-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        let original = temporary.appendingPathComponent("original.zip")
        try data.write(to: original, options: .atomic)
        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        let staged = temporary.appendingPathComponent("model", isDirectory: true)
        try files.createDirectory(at: staged, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", original.path, extracted.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.extractionFailed }
        guard let contents = files.enumerator(at: extracted, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ImportError.invalidContents
        }
        let expected = model == .v4x ? v4xRenderFiles.union(["AL注意点.jpg", "readme_English.txt", "よんでね.txt"]) : requiredFiles
        var copied = Set<String>()
        for case let url as URL in contents {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let name = archivePath(for: url, model: model)
            guard expected.contains(name) else { continue }
            let target = staged.appendingPathComponent(name)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: url, to: target)
            copied.insert(name)
        }
        guard copied == expected else { throw ImportError.invalidContents }
        try install(staged: staged, at: destination, temporary: temporary)
        return model
    }

    private static func archivePath(for url: URL, model: Model) -> String {
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "pmx" { return "miku.pmx" }
        if model == .v4x {
            if url.deletingLastPathComponent().lastPathComponent == "tex" { return "tex/\(name)" }
            if url.pathExtension == "jpg" { return "AL注意点.jpg" }
            if url.pathExtension == "txt", name != "readme_English.txt" { return "よんでね.txt" }
        } else if name.hasPrefix("ReadMe_"), name.hasSuffix(".txt"),
                  name != "ReadMe_Tda.txt", name != "ReadMe_Tda_English.txt" {
            return "ReadMe_金子卵黄.txt"
        }
        return name
    }

    static func importCustomModel(from source: URL, destination: URL = importedDirectory(for: .custom)) throws {
        importLock.lock()
        defer { importLock.unlock() }
        let files = FileManager.default
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let model = try source.resourceValues(forKeys: properties)
        let limit = 64 * 1_024 * 1_024
        guard source.pathExtension.lowercased() == "pmx", model.isRegularFile == true, model.isSymbolicLink == false,
              let modelSize = model.fileSize, (17...limit).contains(modelSize) else { throw ImportError.invalidContents }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        var pmx = PMXTextureReader(data: data)
        let texturePaths = try pmx.paths()
        let directory = source.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".pmx-import-\(UUID().uuidString)", isDirectory: true)
        let staged = temporary.appendingPathComponent("model", isDirectory: true)
        try files.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        try data.write(to: staged.appendingPathComponent("miku.pmx"))

        var total = modelSize
        for relative in Set(texturePaths) {
            let url = directory.appendingPathComponent(relative).standardizedFileURL
            guard url.resolvingSymlinksInPath().path == url.path else { throw ImportError.invalidContents }
            let values = try url.resourceValues(forKeys: properties)
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  let size = values.fileSize, (1...limit).contains(size) else { throw ImportError.invalidContents }
            total += size
            guard total <= 256 * 1_024 * 1_024 else { throw ImportError.invalidContents }
            let target = staged.appendingPathComponent(relative)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: url, to: target)
        }
        try install(staged: staged, at: destination, temporary: temporary)
    }

    private struct PMXTextureReader {
        let data: Data
        private var offset = 0

        init(data: Data) { self.data = data }

        mutating func paths() throws -> [String] {
            guard try take(4) == Data("PMX ".utf8) else { throw ImportError.invalidContents }
            let version = Float(bitPattern: try word())
            guard version == 2 || version == 2.1, try byte() == 8 else { throw ImportError.invalidContents }
            let encoding = try byte()
            let extraUV = try byte()
            let indexSize = try byte()
            try skip(2)
            let boneIndexSize = try byte()
            try skip(2)
            guard encoding <= 1, extraUV <= 4, [1, 2, 4].contains(indexSize),
                  [1, 2, 4].contains(boneIndexSize) else { throw ImportError.invalidContents }
            for _ in 0..<4 { try skip(count(maximum: 1_024 * 1_024)) }
            let vertices = try count(maximum: 1_000_000)
            for _ in 0..<vertices {
                try skip(32 + extraUV * 16)
                let weightSize: Int
                switch try byte() {
                case 0: weightSize = boneIndexSize
                case 1: weightSize = boneIndexSize * 2 + 4
                case 2: weightSize = boneIndexSize * 4 + 16
                case 3: weightSize = boneIndexSize * 2 + 40
                default: throw ImportError.invalidContents
                }
                try skip(weightSize + 4)
            }
            let indices = try count(maximum: 6_000_000)
            guard indices.isMultiple(of: 3) else { throw ImportError.invalidContents }
            try skip(indices * indexSize)
            let textureCount = try count(maximum: 256)
            return try (0..<textureCount).map { _ in
                let length = try count(maximum: 2_048)
                let bytes = try take(length)
                guard let text = String(data: bytes, encoding: encoding == 0 ? .utf16LittleEndian : .utf8) else {
                    throw ImportError.invalidContents
                }
                let path = text.replacingOccurrences(of: "\\", with: "/")
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count <= 8, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") }),
                      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      textureExtensions.contains((path as NSString).pathExtension.lowercased()) else {
                    throw ImportError.invalidContents
                }
                return path
            }
        }

        private mutating func take(_ amount: Int) throws -> Data {
            let start = offset
            try skip(amount)
            return data[start..<offset]
        }

        private mutating func skip(_ amount: Int) throws {
            guard (0...data.count - offset).contains(amount) else { throw ImportError.invalidContents }
            offset += amount
        }

        private mutating func byte() throws -> Int {
            let start = offset
            try skip(1)
            return Int(data[start])
        }

        private mutating func word() throws -> UInt32 {
            let start = offset
            try skip(4)
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: UInt32.self).littleEndian }
        }

        private mutating func count(maximum: Int) throws -> Int {
            let value = Int(try word())
            guard value <= maximum else { throw ImportError.invalidContents }
            return value
        }
    }

    private static func install(staged: URL, at destination: URL, temporary: URL) throws {
        let files = FileManager.default
        let previous = temporary.appendingPathComponent("previous", isDirectory: true)
        let replacing = files.fileExists(atPath: destination.path)
        if replacing { try files.moveItem(at: destination, to: previous) }
        do {
            try files.moveItem(at: staged, to: destination)
        } catch {
            if replacing { try files.moveItem(at: previous, to: destination) }
            throw error
        }
    }
}
