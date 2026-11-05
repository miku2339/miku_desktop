import CryptoKit
import Foundation

extension Notification.Name {
    static let mikuCharacterModelChanged = Notification.Name("mikuCharacterModelChanged")
}

enum CharacterModelStore {
    enum ImportError: Error {
        case invalidArchive
        case invalidContents
        case extractionFailed
    }

    static let authorURL = URL(string: "https://bowlroll.net/file/16344")!
    private static let originalSHA256 = "79baabda41248efe06a3e401ae137f34ce8a20b73db6f76c9039ff9c6b673f92"
    private static let importLock = NSLock()
    private static let requiredFiles: Set<String> = [
        "miku.pmx", "body00_s.bmp", "body01_s.bmp", "body02_MikuAp.tga", "hair_MikuAp.png", "hair_s.bmp",
        "k_Asi2.png", "k_face_MikuAp.tga", "k_Hada.png", "k_hika.png", "k_huku1.png", "k_huku2.png",
        "skin_s.bmp", "toon_defo.bmp", "toon_hair.bmp", "toon_skin.bmp",
        "ReadMe_Tda.txt", "ReadMe_Tda_English.txt", "ReadMe_金子卵黄.txt"
    ]

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MikuDesktop/CharacterModels/tda", isDirectory: true)
    }

    static var currentModelName: String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Wallpaper/assets/companion-model/tda/miku.pmx")
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("miku.pmx").path)
            || bundled.map { FileManager.default.fileExists(atPath: $0.path) } == true
            ? "Tda / 金子卵黄 v1.1" : "Animasa"
    }

    static func importArchive(from archive: URL) throws {
        try importArchive(from: archive, destination: directory)
    }

    static func importArchive(from archive: URL, destination: URL) throws {
        importLock.lock()
        defer { importLock.unlock() }
        let files = FileManager.default
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 12 * 1_024 * 1_024 else { throw ImportError.invalidArchive }
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == originalSHA256 else { throw ImportError.invalidArchive }

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
        for case let url as URL in contents {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            var name = url.lastPathComponent
            if url.pathExtension.lowercased() == "pmx" { name = "miku.pmx" }
            // ditto escapes the legacy Shift-JIS name on some macOS versions.
            if name.hasPrefix("ReadMe_"), name.hasSuffix(".txt"),
               name != "ReadMe_Tda.txt", name != "ReadMe_Tda_English.txt" { name = "ReadMe_金子卵黄.txt" }
            guard requiredFiles.contains(name) else { continue }
            try files.copyItem(at: url, to: staged.appendingPathComponent(name))
        }
        guard Set(try files.contentsOfDirectory(atPath: staged.path)) == requiredFiles else {
            throw ImportError.invalidContents
        }
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
