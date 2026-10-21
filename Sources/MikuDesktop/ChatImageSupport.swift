import AppKit
import UniformTypeIdentifiers

/// Pictures in the chat: turning whatever the user drops, pastes or picks into a small JPEG
/// the local model can read, and the window background that accepts dropped pictures.
enum ChatImage {
    /// Longest side sent to the model. Plenty for a vision model, small enough to stay quick.
    static let maxSide: CGFloat = 1280

    static func jpeg(from image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        guard width >= 1, height >= 1 else { return nil }
        let scale = min(1, maxSide / max(width, height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        // JPEG has no transparency: put transparent pictures (stickers, screenshots) on white.
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        context.imageInterpolation = .high
        context.cgContext.draw(source, in: CGRect(origin: .zero, size: size))
        context.flushGraphics()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    static func jpeg(contentsOf url: URL) -> Data? {
        guard isImageFile(url), let image = NSImage(contentsOf: url) else { return nil }
        return jpeg(from: image)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// A picture on the pasteboard: an image file first, then image data.
    static func jpeg(from pasteboard: NSPasteboard) -> Data? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first(where: isImageFile) {
            return jpeg(contentsOf: url)
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return jpeg(from: image)
        }
        return nil
    }

    /// Whether pasting should attach a picture rather than insert text.
    static func pasteboardHasPicture(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           urls.contains(where: isImageFile) {
            return true
        }
        // Copied images often carry text too (a web page, a file name): text wins then.
        let hasText = pasteboard.string(forType: .string)?.isEmpty == false
        return !hasText && NSImage.canInit(with: pasteboard)
    }
}

/// The chat window's content view: the usual Miku background, and a drop target for pictures.
final class ChatDropView: NSView {
    var onDropImage: ((Data) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let background = MikuBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ChatImage.pasteboardHasPicture(sender.draggingPasteboard) || hasImageFile(sender) else { return [] }
        showHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showHighlight(false)
        guard let data = ChatImage.jpeg(from: sender.draggingPasteboard) else { return false }
        onDropImage?(data)
        return true
    }

    private func hasImageFile(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.contains(where: ChatImage.isImageFile)
    }

    /// A teal outline around the window while a picture is dragged over it.
    private func showHighlight(_ on: Bool) {
        wantsLayer = true
        layer?.borderWidth = on ? 3 : 0
        layer?.borderColor = MikuTheme.teal.cgColor
        layer?.cornerRadius = 10
    }
}
