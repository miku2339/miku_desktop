import AppKit
import WebKit

enum MemoryPhotoCapture {
    @MainActor
    static func companionStatus(in webView: WKWebView) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("window.mikuCompanion?.status?.() ?? null") { result, error in
                if error != nil {
                    continuation.resume(throwing: MemoryPhotoCaptureError.notReady)
                } else if let status = result as? [String: Any] {
                    continuation.resume(returning: status)
                } else {
                    continuation.resume(throwing: MemoryPhotoCaptureError.notReady)
                }
            }
        }
    }

    @MainActor
    static func capture(
        background backgroundWebView: WKWebView,
        character characterWebView: WKWebView,
        scene: String
    ) async throws -> CapturedScene {
        guard !scene.isEmpty,
              backgroundWebView.bounds.width > 1,
              backgroundWebView.bounds.height > 1,
              characterWebView.bounds.size == backgroundWebView.bounds.size else {
            throw MemoryPhotoCaptureError.notReady
        }

        let pointWidth = backgroundWebView.bounds.width
        let background = try await snapshot(backgroundWebView, pointWidth: pointWidth)
        let character = try await snapshot(characterWebView, pointWidth: pointWidth)
        guard MemoryAlbum.isUsableImage(background), MemoryAlbum.isUsableImage(character) else {
            throw MemoryPhotoCaptureError.emptyLayer
        }
        guard let image = composite(background: background, character: character),
              MemoryAlbum.isUsableImage(image) else {
            throw MemoryPhotoCaptureError.snapshotFailed
        }
        return CapturedScene(image: image, capturedAt: Date(), scene: scene)
    }

    @MainActor
    private static func snapshot(_ view: WKWebView, pointWidth: CGFloat) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        // WKSnapshotConfiguration uses points. The returned NSImage retains the screen's
        // backing scale, so multiplying here would allocate a four-times-larger Retina image.
        configuration.snapshotWidth = NSNumber(value: Double(pointWidth))
        return try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: configuration) { image, error in
                if error != nil {
                    continuation.resume(throwing: MemoryPhotoCaptureError.snapshotFailed)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: MemoryPhotoCaptureError.snapshotFailed)
                }
            }
        }
    }

    private static func composite(background: NSImage, character: NSImage) -> NSImage? {
        guard let backgroundImage = background.cgImage(forProposedRect: nil, context: nil, hints: nil),
              backgroundImage.width > 1, backgroundImage.height > 1 else { return nil }
        let width = backgroundImage.width
        let height = backgroundImage.height
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
        let destination = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.draw(in: destination, from: .zero, operation: .copy, fraction: 1)
        character.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: destination.size)
        image.addRepresentation(bitmap)
        return image
    }
}
