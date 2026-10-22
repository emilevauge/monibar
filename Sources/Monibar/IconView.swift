import AppKit

/// Menu bar capsule: a track tinted with the load color, filled from the left
/// in proportion to CPU, the number in white on top, a thin white border. Built from CALayers, so
/// an update only moves the fill edge and, when the number changes, swaps
/// the text: no image is redrawn.
final class IconView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let capsule = NSSize(width: 21, height: 14)
    static let size = NSSize(width: capsule.width, height: 22)

    private let track = CALayer()
    private let fill = CALayer()
    private let text = CATextLayer()
    private var level: Level?

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

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        let box = CGRect(x: 0, y: (Self.size.height - Self.capsule.height) / 2,
                         width: Self.capsule.width, height: Self.capsule.height)
        track.frame = box
        track.cornerRadius = 4
        track.masksToBounds = true
        // Drawn above the fill: keeps the capsule's edge visible on any
        // wallpaper, whatever the load color.
        track.borderWidth = 1
        track.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        fill.anchorPoint = .zero
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: box.height)
        track.addSublayer(fill)

        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        text.frame = CGRect(x: 0, y: (box.height - lineHeight) / 2, width: box.width, height: lineHeight)
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        track.addSublayer(text)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks and hover go to the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        level.map(applyColors)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// `value` is the CPU load from 0 to 1.
    func update(value: Double) {
        let v = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = "\(Int((v * 100).rounded()))"
        fill.bounds.size.width = (Self.capsule.width * v).rounded()
        let newLevel = Level(v)
        if newLevel != level {
            level = newLevel
            applyColors(newLevel)
        }
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
        track.backgroundColor = color.copy(alpha: 0.45)
        CATransaction.commit()
    }
}
