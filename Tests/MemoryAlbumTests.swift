import AppKit
import Foundation

@main
struct MemoryAlbumTests {
    private static var checks = 0
    private static var failures: [String] = []

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) {
        checks += 1
        do {
            try operation()
            failures.append("\(message): did not throw")
        } catch {}
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miku-album-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func testImage(width: Int = 2_800, height: Int = 180) -> NSImage {
        let bitmap = NSBitmapImageRep(
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
        )!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.68, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedRed: 0.92, green: 0.19, blue: 0.49, alpha: 1).setFill()
        NSRect(x: width / 3, y: 0, width: width / 3, height: height).fill()
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private static func transparentImage() -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(bitmap)
        return image
    }

    private static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let root = temporaryDirectory("main")
        defer { try? FileManager.default.removeItem(at: root) }
        let albumURL = root.appendingPathComponent("album", isDirectory: true)
        let album = MemoryAlbum(directoryURL: albumURL)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let entry = try album.add(
            CapturedScene(image: testImage(), capturedAt: capturedAt, scene: "shibuya"),
            title: "放學後",
            note: "一起散步",
            category: .everyday
        )
        expect(album.entries.count == 1, "add stores one entry")
        expect(FileManager.default.fileExists(atPath: album.metadataURL.path), "add writes metadata")
        let imageURL = album.imageURL(for: entry)!
        expect(FileManager.default.fileExists(atPath: imageURL.path), "add writes the photograph")
        let savedBitmap = NSBitmapImageRep(data: try Data(contentsOf: imageURL))!
        expect(max(savedBitmap.pixelsWide, savedBitmap.pixelsHigh) <= Int(MemoryAlbum.maxImageSide), "saved photograph respects the longest-side limit")

        let reloaded = MemoryAlbum(directoryURL: albumURL)
        expect(reloaded.loadError == nil, "valid metadata reloads without an error")
        expect(reloaded.entries == album.entries, "metadata and fields survive a reload")
        try reloaded.update(id: entry.id, title: "澀谷散步", note: "新的小記", category: .achievement)
        let updated = MemoryAlbum(directoryURL: albumURL).entries.first
        expect(updated?.title == "澀谷散步" && updated?.category == .achievement, "edited details persist")

        let exportURL = root.appendingPathComponent("export.jpg")
        try reloaded.export(id: entry.id, to: exportURL)
        let exportedData = try Data(contentsOf: exportURL)
        expect(exportedData.count > 0, "export writes a usable file")
        try reloaded.delete(id: entry.id)
        expect(reloaded.entries.isEmpty, "delete removes metadata entry")
        expect(!FileManager.default.fileExists(atPath: imageURL.path), "delete removes the photograph")
        expect(MemoryAlbum(directoryURL: albumURL).entries.isEmpty, "delete persists after reload")

        let invalidURL = root.appendingPathComponent("invalid", isDirectory: true)
        let invalidAlbum = MemoryAlbum(directoryURL: invalidURL)
        expectThrows("transparent photographs are rejected") {
            _ = try invalidAlbum.add(CapturedScene(image: transparentImage(), capturedAt: Date(), scene: "room"))
        }
        expect(!FileManager.default.fileExists(atPath: invalidURL.path), "invalid images do not create album files")

        let corruptURL = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corruptURL.appendingPathComponent("album.json"))
        let corruptAlbum = MemoryAlbum(directoryURL: corruptURL)
        expect(corruptAlbum.entries.isEmpty && corruptAlbum.loadError != nil, "damaged metadata fails closed")
        let corruptData = try Data(contentsOf: corruptAlbum.metadataURL)
        expectThrows("damaged metadata cannot be overwritten by a new entry") {
            _ = try corruptAlbum.add(CapturedScene(image: testImage(width: 320, height: 180), capturedAt: Date(), scene: "room"))
        }
        expect((try? Data(contentsOf: corruptAlbum.metadataURL)) == corruptData, "failed add preserves damaged metadata for recovery")
        let corruptFiles = try FileManager.default.contentsOfDirectory(atPath: corruptURL.path)
        expect(!corruptFiles.contains(where: { $0.hasSuffix(".jpg") }), "failed add beside damaged metadata leaves no orphan photo")

        let traversalURL = root.appendingPathComponent("traversal", isDirectory: true)
        try FileManager.default.createDirectory(at: traversalURL, withIntermediateDirectories: true)
        let outsideURL = root.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outsideURL)
        let unsafeManifest: [String: Any] = [
            "version": 1,
            "entries": [[
                "id": UUID().uuidString,
                "title": "Unsafe",
                "note": "",
                "category": "everyday",
                "capturedAt": ISO8601DateFormatter().string(from: Date()),
                "scene": "room",
                "imageName": "../outside.jpg"
            ]]
        ]
        try JSONSerialization.data(withJSONObject: unsafeManifest).write(
            to: traversalURL.appendingPathComponent("album.json")
        )
        let traversalAlbum = MemoryAlbum(directoryURL: traversalURL)
        expect(traversalAlbum.entries.isEmpty, "unsafe image paths are ignored")
        expect(FileManager.default.fileExists(atPath: outsideURL.path), "unsafe paths cannot access an outside file")

        let failureURL = root.appendingPathComponent("write-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: true)
        let blockerURL = failureURL.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blockerURL)
        let failingAlbum = MemoryAlbum(
            directoryURL: failureURL,
            metadataURL: blockerURL.appendingPathComponent("album.json")
        )
        expectThrows("metadata failure is reported") {
            _ = try failingAlbum.add(CapturedScene(image: testImage(width: 320, height: 180), capturedAt: Date(), scene: "room"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: failureURL.path)
            .filter { $0.hasSuffix(".jpg") }
        expect(leftovers.isEmpty, "metadata failure cleans up the orphan photograph")
        expect(failingAlbum.entries.isEmpty, "metadata failure rolls back the in-memory entry")

        let rollbackAlbumURL = root.appendingPathComponent("delete-rollback", isDirectory: true)
        let metadataFolder = root.appendingPathComponent("delete-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        let rollbackAlbum = MemoryAlbum(
            directoryURL: rollbackAlbumURL,
            metadataURL: metadataFolder.appendingPathComponent("album.json")
        )
        let rollbackEntry = try rollbackAlbum.add(
            CapturedScene(image: testImage(width: 320, height: 180), capturedAt: Date(), scene: "room")
        )
        let rollbackImageURL = rollbackAlbum.imageURL(for: rollbackEntry)!
        try FileManager.default.removeItem(at: metadataFolder)
        try Data("not a directory".utf8).write(to: metadataFolder)
        expectThrows("delete reports a metadata write failure") {
            try rollbackAlbum.delete(id: rollbackEntry.id)
        }
        expect(rollbackAlbum.entries.contains(where: { $0.id == rollbackEntry.id }), "failed delete restores the in-memory entry")
        expect(FileManager.default.fileExists(atPath: rollbackImageURL.path), "failed delete restores the parked photograph")

        let protectedURL = root.appendingPathComponent("protected-delete", isDirectory: true)
        let protectedAlbum = MemoryAlbum(directoryURL: protectedURL)
        let protectedEntry = try protectedAlbum.add(
            CapturedScene(image: testImage(width: 320, height: 180), capturedAt: Date(), scene: "room")
        )
        let protectedImageURL = protectedAlbum.imageURL(for: protectedEntry)!
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedURL.path)
        expectThrows("image move failure aborts delete") {
            try protectedAlbum.delete(id: protectedEntry.id)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedURL.path)
        expect(protectedAlbum.entries.contains(where: { $0.id == protectedEntry.id }), "image move failure preserves metadata in memory")
        expect(FileManager.default.fileExists(atPath: protectedImageURL.path), "image move failure leaves the photograph in place")

        let previousLanguage = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "interfaceLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "interfaceLanguage")
            }
        }
        let localizationURL = root.appendingPathComponent("localization", isDirectory: true)
        let localizationAlbum = MemoryAlbum(directoryURL: localizationURL)
        let localizedCapture = CapturedScene(
            image: testImage(width: 320, height: 180),
            capturedAt: capturedAt,
            scene: "musicroom"
        )
        UserDefaults.standard.set("zh-Hant", forKey: "interfaceLanguage")
        let controller = MemoryAlbumWindowController(album: localizationAlbum) { localizedCapture }
        controller.presentAndCapture()
        let captureReady = waitUntil { (controller.window?.contentView.map(allViews(in:)))?
            .compactMap { $0 as? NSButton }
            .contains(where: { $0.title == "加入相簿" }) == true }
        expect(captureReady, "manual capture becomes available for editing")

        let views = allViews(in: controller.window!.contentView!)
        let titleField = views.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "為這刻起個名字" }!
        let noteView = views.compactMap { $0 as? NSTextView }.first!
        let categoryButton = views.compactMap { $0 as? NSPopUpButton }.first!
        titleField.stringValue = "草稿標題"
        noteView.string = "草稿小記"
        categoryButton.selectItem(at: 2)
        controller.close()

        UserDefaults.standard.set("en", forKey: "interfaceLanguage")
        controller.present()
        let englishViews = allViews(in: controller.window!.contentView!)
        let englishLabels = englishViews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        let englishButtons = englishViews.compactMap { $0 as? NSButton }
        expect(titleField.placeholderString == "Name this moment", "English title placeholder refreshes")
        expect(Set(["Shared Memories", "Title", "Note", "Category"]).isSubset(of: Set(englishLabels)), "English static labels refresh")
        expect(englishLabels.contains("Photos you take are stored separately. Resetting conversation memory will not delete this album."), "English preservation note refreshes")
        expect(categoryButton.itemTitles == ["Everyday", "First meeting", "Birthday", "Something we achieved"], "English category choices refresh")
        expect(titleField.stringValue == "草稿標題" && noteView.string == "草稿小記", "pending capture draft survives English refresh")
        expect(categoryButton.indexOfSelectedItem == 2, "pending capture category survives English refresh")
        expect(englishButtons.contains(where: { $0.title == "Add to album" }), "pending capture survives close and English refresh")

        englishButtons.first(where: { $0.title == "Add to album" })?.performClick(nil)
        expect(localizationAlbum.entries.count == 1, "localized pending capture can still be saved")
        titleField.stringValue = "未儲存標題"
        noteView.string = "未儲存小記"
        categoryButton.selectItem(at: 3)
        controller.close()

        UserDefaults.standard.set("ja", forKey: "interfaceLanguage")
        controller.refreshLocalization()
        controller.present()
        let japaneseViews = allViews(in: controller.window!.contentView!)
        let japaneseLabels = japaneseViews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        let japaneseButtons = japaneseViews.compactMap { $0 as? NSButton }
        expect(titleField.placeholderString == "この瞬間に名前をつける", "Japanese title placeholder refreshes")
        expect(Set(["思い出アルバム", "タイトル", "メモ", "カテゴリー"]).isSubset(of: Set(japaneseLabels)), "Japanese static labels refresh")
        expect(japaneseLabels.contains("撮影した写真は会話の記憶とは別に保存されます。会話の記憶をリセットしても削除されません。"), "Japanese preservation note refreshes")
        expect(categoryButton.itemTitles == ["日常", "初めて会った日", "誕生日", "一緒に成し遂げたこと"], "Japanese category choices refresh")
        expect(titleField.stringValue == "未儲存標題" && noteView.string == "未儲存小記", "selected photo draft survives Japanese refresh")
        expect(categoryButton.indexOfSelectedItem == 3, "selected photo category survives Japanese refresh")
        expect(japaneseButtons.contains(where: { $0.title == "保存" && $0.isEnabled }), "selected photo survives close and Japanese refresh")
        expect(japaneseViews.compactMap { $0 as? NSImageView }.contains(where: { $0.image != nil }), "selected photo preview survives Japanese refresh")
        controller.close()

        if failures.isEmpty {
            print("MemoryAlbumTests: \(checks) checks passed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
