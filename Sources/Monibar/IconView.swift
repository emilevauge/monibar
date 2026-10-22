import AppKit

/// Menu bar icon: a CPU chip whose body fills from the bottom with the load,
/// green under 50 %, orange under 80 %, red above, three pins on each side.
/// No number: the fill and its color tell the load. Without Internet, a
/// crossed-out Wi-Fi in the outline's ink shows in the middle of the chip.
///
/// Built from CALayers, so an update only moves the fill edge: no image is
/// redrawn.
final class IconView: NSView {
    private static let body: CGFloat = 16
    private static let pinLength: CGFloat = 2
    /// Same stroke as Calbar's calendar page, so both icons match.
    private static let pinWidth: CGFloat = 1.3
    private static let outline: CGFloat = 1.3
    static let size = NSSize(width: body + 2 * pinLength + 1, height: 22)

    private let track = CALayer()
    private let fill = CALayer()
    private let alert = CALayer()
    private let pins = (0..<12).map { _ in CALayer() }
    private var level: Level?
    private var shownHeight: CGFloat = -1
    private(set) var offline = false

    /// Green under 50 %, orange under 80 %, red above.
    private enum Level {
        case low, mid, high

        init(_ v: Double) {
            self = v < 0.5 ? .low : v < 0.8 ? .mid : .high
        }

        var color: NSColor {
            switch self {
            case .low: .systemGreen
            case .mid: .systemOrange
            case .high: .systemRed
            }
        }
    }

    private var box: CGRect {
        CGRect(x: (Self.size.width - Self.body) / 2, y: (Self.size.height - Self.body) / 2,
               width: Self.body, height: Self.body)
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        let box = self.box

        for (i, pin) in pins.enumerated() {
            let offset = CGFloat(i % 3 - 1) * 4.5 - Self.pinWidth / 2
            pin.frame = switch i / 3 {
            case 0: CGRect(x: box.minX - Self.pinLength, y: box.midY + offset, width: Self.pinLength, height: Self.pinWidth)
            case 1: CGRect(x: box.maxX, y: box.midY + offset, width: Self.pinLength, height: Self.pinWidth)
            case 2: CGRect(x: box.midX + offset, y: box.maxY, width: Self.pinWidth, height: Self.pinLength)
            default: CGRect(x: box.midX + offset, y: box.minY - Self.pinLength, width: Self.pinWidth, height: Self.pinLength)
            }
            layer?.addSublayer(pin)
        }

        track.frame = box
        track.cornerRadius = 3.2
        track.masksToBounds = true
        track.borderWidth = Self.outline
        fill.anchorPoint = .zero
        fill.frame = CGRect(x: 0, y: 0, width: box.width, height: 0)
        track.addSublayer(fill)

        layer?.addSublayer(track)

        alert.frame = box
        alert.contentsGravity = .center
        alert.isHidden = true
        layer?.addSublayer(alert)
        applyInk()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks and hover go to the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk()
        level.map(applyColors)
        if offline { renderAlert() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if offline { renderAlert() }
    }

    /// Shows or hides the no-Internet alert.
    func setOffline(_ on: Bool) {
        guard on != offline else { return }
        offline = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if on { renderAlert() }
        alert.isHidden = !on
        CATransaction.commit()
    }

    /// Crossed-out Wi-Fi in the outline's ink, white on a dark menu bar and
    /// black on a light one, rendered at the screen's scale. Bold, so it
    /// holds over the colored fill.
    private func renderAlert() {
        var ink = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        // Opaque: the label color is slightly translucent, which washes the
        // symbol out over the fill.
        ink = ink.withAlphaComponent(1)
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .heavy)
            .applying(.init(paletteColors: [ink]))
        guard let image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var rect = NSRect(origin: .zero, size: image.size)
        alert.contents = image.cgImage(forProposedRect: &rect, context: nil,
                                       hints: [.ctm: AffineTransform(scale: scale)])
        alert.contentsScale = scale
    }

    /// `value` is the CPU load from 0 to 1.
    func update(value: Double) {
        let v = min(1, max(0, value))
        let number = Int((v * 100).rounded())
        let height = (Self.body * v).rounded()
        // From the rounded number, so 50 % is never green.
        let newLevel = Level(Double(number) / 100)
        guard height != shownHeight || newLevel != level else { return }
        shownHeight = height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds.size.height = height
        if newLevel != level {
            level = newLevel
            applyColors(newLevel)
        }
        CATransaction.commit()
    }

    /// Pins and outline in the menu bar's ink.
    private func applyInk() {
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pins.forEach { $0.backgroundColor = ink }
        track.borderColor = ink
        CATransaction.commit()
    }

    /// System colors resolved for the menu bar's appearance.
    private func applyColors(_ level: Level) {
        var color = level.color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = level.color.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color
        track.backgroundColor = color.copy(alpha: 0.35)
        CATransaction.commit()
    }
}
