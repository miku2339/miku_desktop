import AppKit

/// Shared colours, fonts and small controls for the Miku-styled windows.
enum MikuTheme {
    // Miku teal (#39C5BB) with a pink accent taken from her hair ties.
    static let teal = hex(0x39C5BB)
    static let pink = hex(0xE5307E)
    static let deepTeal = dynamic(light: hex(0x13858A), dark: hex(0x66E0D6))
    static let windowBackground = dynamic(light: hex(0xF2FAF9), dark: hex(0x0F1A1D))
    static let cardBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x182629))
    static let cardBorder = dynamic(light: hex(0x39C5BB, alpha: 0.22), dark: hex(0x39C5BB, alpha: 0.26))
    static let mikuBubble = dynamic(light: hex(0xE3F6F4), dark: hex(0x1D3638))
    static let userBubble = dynamic(light: hex(0x2FB5AB), dark: hex(0x24978F))
    static let primaryText = dynamic(light: hex(0x18343A), dark: hex(0xE6F6F5))
    static let secondaryText = dynamic(light: hex(0x5E7E83), dark: hex(0x93B4B7))
    static let inputBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1C2C30))
    static let errorBackground = dynamic(light: hex(0xFDEBF2), dark: hex(0x3A1D2A))
    static let online = hex(0x2FC48D)
    static let offline = hex(0xE5307E)
    static let checking = hex(0xF0B43C)

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else { return base }
        return rounded
    }

    /// Circular crop of the bundled portrait, used as Miku's avatar.
    static let avatar: NSImage = makeAvatar()

    private static func makeAvatar() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let portraitURL = Bundle.main.resourceURL?
            .appendingPathComponent("Wallpaper/assets/miku.png")
        var face: CGImage?
        if let portraitURL,
           let source = NSImage(contentsOf: portraitURL),
           let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = CGFloat(cgImage.width) / 1024
            face = cgImage.cropping(to: CGRect(x: 300 * scale, y: 110 * scale, width: 500 * scale, height: 500 * scale))
        }
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            circle.addClip()
            hex(0xE3F6F4).setFill()
            rect.fill()
            if let face, let context = NSGraphicsContext.current?.cgContext {
                context.interpolationQuality = .high
                context.draw(face, in: rect)
            } else {
                let note = NSAttributedString(string: "♪", attributes: [
                    .font: font(150, .bold),
                    .foregroundColor: teal
                ])
                let noteSize = note.size()
                note.draw(at: NSPoint(x: rect.midX - noteSize.width / 2, y: rect.midY - noteSize.height / 2))
            }
            return true
        }
    }
}

/// Layer-backed rounded rectangle that re-resolves its colours when the appearance changes.
class MikuCardView: NSView {
    var fillColor: NSColor = MikuTheme.cardBackground { didSet { needsDisplay = true } }
    var borderColor: NSColor? = MikuTheme.cardBorder { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 16 { didSet { needsDisplay = true } }
    var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = borderColor?.cgColor
        }
        layer.borderWidth = borderColor == nil ? 0 : 1
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = maskedCorners
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Flipped container so stacks lay out from the top inside scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Window background view that follows light / dark mode.
final class MikuBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MikuTheme.windowBackground.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Pill-shaped button drawn in Miku colours.
final class MikuPillButton: NSButton {
    enum Style {
        case primary
        case soft
        case accent
    }

    var style: Style = .primary { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var horizontalPadding: CGFloat = 14 { didSet { invalidateIntrinsicContentSize() } }
    var iconOnly = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var controlHeight: CGFloat = 30 { didSet { invalidateIntrinsicContentSize() } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingAreaRef: NSTrackingArea?

    convenience init(title: String, symbolName: String? = nil, style: Style = .primary, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.symbolName = symbolName
        self.style = style
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        font = MikuTheme.font(13, .semibold)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: controlHeight, height: controlHeight) }
        let textWidth = (title as NSString).size(withAttributes: [.font: font ?? MikuTheme.font(13, .semibold)]).width
        let iconWidth: CGFloat = symbolName == nil ? 0 : 20
        return NSSize(width: ceil(textWidth + iconWidth + horizontalPadding * 2), height: controlHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let pressed = isHighlighted
        let fill: NSColor
        let foreground: NSColor
        switch style {
        case .primary:
            fill = MikuTheme.teal
            foreground = .white
        case .accent:
            fill = MikuTheme.pink
            foreground = .white
        case .soft:
            fill = MikuTheme.teal.withAlphaComponent(0.14)
            foreground = MikuTheme.deepTeal
        }
        var resolvedFill = fill
        if pressed { resolvedFill = fill.blended(withFraction: 0.18, of: .black) ?? fill }
        else if hovering { resolvedFill = style == .soft ? MikuTheme.teal.withAlphaComponent(0.24) : (fill.blended(withFraction: 0.1, of: .white) ?? fill) }
        if !isEnabled { resolvedFill = resolvedFill.withAlphaComponent(0.4) }
        resolvedFill.setFill()
        path.fill()

        let tint = isEnabled ? foreground : foreground.withAlphaComponent(0.7)
        var icon: NSImage?
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconOnly ? 13 : 12, weight: .semibold)) {
            icon = tinted(image, tint)
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? MikuTheme.font(13, .semibold), .foregroundColor: tint]
        let textSize = iconOnly ? .zero : (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = icon == nil ? 0 : (icon!.size.width + (iconOnly ? 0 : 6))
        let contentWidth = textSize.width + iconWidth
        var x = bounds.midX - contentWidth / 2
        if let icon {
            let iconRect = NSRect(x: x, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
            icon.draw(in: iconRect)
            x += iconWidth
        }
        if !iconOnly {
            (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return result
    }
}

/// Round avatar with a teal ring.
final class MikuAvatarView: NSImageView {
    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        image = MikuTheme.avatar
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        layer?.borderWidth = size > 32 ? 2 : 1.5
        layer?.borderColor = MikuTheme.teal.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Small coloured dot for connection state.
final class StatusDotView: NSView {
    var color: NSColor = MikuTheme.checking { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

extension NSTextField {
    static func mikuLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = MikuTheme.primaryText) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = MikuTheme.font(size, weight)
        label.textColor = color
        return label
    }
}
