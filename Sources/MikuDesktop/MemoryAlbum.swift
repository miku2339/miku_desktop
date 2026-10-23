import AppKit
import Foundation

struct CapturedScene {
    let image: NSImage
    let capturedAt: Date
    let scene: String
}

enum MemoryPhotoCaptureError: Error {
    case notReady
    case snapshotFailed
    case emptyLayer
    case sceneUnavailable
}

extension MemoryPhotoCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notReady: return "Miku and the scene are not ready yet."
        case .snapshotFailed: return "The current scene could not be photographed."
        case .emptyLayer: return "The photograph was empty, so it was not saved."
        case .sceneUnavailable: return "The current scene could not be identified."
        }
    }
}

/// User-created photographs are stored separately from conversation memory and are never
/// changed by a conversation-memory reset.
final class MemoryAlbum {
    enum Category: String, Codable, CaseIterable {
        case everyday
        case firstMeeting
        case birthday
        case achievement
    }

    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        var title: String
        var note: String
        var category: Category
        let capturedAt: Date
        let scene: String
        let imageName: String
    }

    enum AlbumError: Error {
        case invalidImage
        case invalidImageName
        case entryNotFound
        case damagedMetadata
    }

    static let changed = Notification.Name("MikuMemoryAlbumChanged")
    static let maxImageSide: CGFloat = 2_560

    static let shared: MemoryAlbum = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return MemoryAlbum(directoryURL: base.appendingPathComponent("MikuDesktop/album", isDirectory: true))
    }()

    private struct Manifest: Codable {
        var version = 1
        var entries: [Entry]
    }

    private let fileManager: FileManager
    let directoryURL: URL
    let metadataURL: URL
    private(set) var entries: [Entry] = []
    private(set) var loadError: Error?

    init(directoryURL: URL, metadataURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL.standardizedFileURL
        self.metadataURL = (metadataURL ?? directoryURL.appendingPathComponent("album.json")).standardizedFileURL
        reload()
    }

    func reload() {
        loadError = nil
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            entries = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: metadataURL))
            guard manifest.version == 1 else { throw AlbumError.damagedMetadata }
            var seen = Set<UUID>()
            entries = manifest.entries.filter { entry in
                guard seen.insert(entry.id).inserted,
                      Self.isValidImageName(entry.imageName),
                      let url = safeImageURL(named: entry.imageName) else { return false }
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }.sorted { $0.capturedAt > $1.capturedAt }
        } catch {
            entries = []
            loadError = error
        }
    }

    @discardableResult
    func add(
        _ capture: CapturedScene,
        title: String = "",
        note: String = "",
        category: Category = .everyday
    ) throws -> Entry {
        guard loadError == nil else { throw AlbumError.damagedMetadata }
        guard Self.isUsableImage(capture.image), let jpeg = Self.jpeg(from: capture.image) else {
            throw AlbumError.invalidImage
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let imageName = UUID().uuidString.lowercased() + ".jpg"
        guard let imageURL = safeImageURL(named: imageName) else { throw AlbumError.invalidImageName }
        try jpeg.write(to: imageURL, options: .atomic)

        let entry = Entry(
            id: UUID(),
            title: Self.clean(title, limit: 120),
            note: Self.clean(note, limit: 2_000),
            category: category,
            capturedAt: capture.capturedAt,
            scene: Self.clean(capture.scene, limit: 80),
            imageName: imageName
        )
        let previous = entries
        entries.insert(entry, at: 0)
        do {
            try persist(entries)
        } catch {
            entries = previous
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
        notifyChanged()
        return entry
    }

    func update(id: UUID, title: String, note: String, category: Category) throws {
        guard loadError == nil else { throw AlbumError.damagedMetadata }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw AlbumError.entryNotFound }
        let previous = entries[index]
        entries[index].title = Self.clean(title, limit: 120)
        entries[index].note = Self.clean(note, limit: 2_000)
        entries[index].category = category
        do {
            try persist(entries)
        } catch {
            entries[index] = previous
            throw error
        }
        notifyChanged()
    }

    func delete(id: UUID) throws {
        guard loadError == nil else { throw AlbumError.damagedMetadata }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw AlbumError.entryNotFound }
        let entry = entries[index]
        guard let imageURL = safeImageURL(named: entry.imageName) else { throw AlbumError.invalidImageName }
        let parkedURL = directoryURL.appendingPathComponent(".deleting-\(UUID().uuidString)")
        let hadImage = fileManager.fileExists(atPath: imageURL.path)
        if hadImage { try fileManager.moveItem(at: imageURL, to: parkedURL) }

        entries.remove(at: index)
        do {
            try persist(entries)
        } catch {
            entries.insert(entry, at: index)
            if hadImage { try? fileManager.moveItem(at: parkedURL, to: imageURL) }
            throw error
        }
        if hadImage { try? fileManager.removeItem(at: parkedURL) }
        notifyChanged()
    }

    func export(id: UUID, to destination: URL) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw AlbumError.entryNotFound }
        guard let source = safeImageURL(named: entry.imageName), destination.isFileURL else {
            throw AlbumError.invalidImageName
        }
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }

    func imageURL(for entry: Entry) -> URL? {
        safeImageURL(named: entry.imageName)
    }

    private func persist(_ entries: [Entry]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(entries: entries)).write(to: metadataURL, options: .atomic)
    }

    private func safeImageURL(named name: String) -> URL? {
        guard Self.isValidImageName(name) else { return nil }
        let candidate = directoryURL.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directoryURL else { return nil }
        return candidate
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private static func clean(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func isValidImageName(_ name: String) -> Bool {
        guard name.count == 40, name.hasSuffix(".jpg"), !name.contains("/"), !name.contains("\\") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    /// Rejects transparent, all-black and effectively uniform snapshots before any file is written.
    static func isUsableImage(_ image: NSImage) -> Bool {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 1, source.height > 1 else { return false }
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visible = 0
        var darkest = 255
        var brightest = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 8 {
            visible += 1
            let brightness = max(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            darkest = min(darkest, brightness)
            brightest = max(brightest, brightness)
        }
        return visible >= 4 && brightest >= 8 && brightest - darkest >= 3
    }

    private static func jpeg(from image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let scale = min(1, maxImageSide / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
