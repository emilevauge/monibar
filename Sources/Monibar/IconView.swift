import AppKit

/// Menu bar square: a track tinted with the load color, filled from the bottom
/// in proportion to CPU, the number in white on top, a thin white border.
/// Square rather than wide, so it reads as a gauge, not a battery.
/// Without Internet, red dashes run over the white border. Built from
/// CALayers, so an update only moves the fill edge and, when the number
/// changes, swaps the text: no image is redrawn.
final class IconView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    /// "100" only fits in a smaller size.
    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
    static let capsule = NSSize(width: 16, height: 16)
    static let size = NSSize(width: capsule.width, height: 22)

    private let track = CALayer()
    private let fill = CALayer()
    private let text = CATextLayer()
    private let alert = CAShapeLayer()
    private var level: Level?
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
        fill.frame = CGRect(x: 0, y: 0, width: box.width, height: 0)
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

        // Red dashes over the white border: the white gaps keep them visible
        // even on a red gauge.
        alert.frame = box
        alert.path = CGPath(roundedRect: CGRect(origin: .zero, size: box.size).insetBy(dx: 0.75, dy: 0.75),
                            cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        alert.fillColor = nil
        alert.lineWidth = 1.5
        alert.lineDashPattern = [2, 1.5]
        alert.isHidden = true
        layer?.addSublayer(alert)
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

    /// Shows or hides the no-Internet alert.
    func setOffline(_ on: Bool) {
        guard on != offline else { return }
        offline = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alert.strokeColor = NSColor.systemRed.usingColorSpace(.sRGB)?.cgColor
        alert.isHidden = !on
        CATransaction.commit()
    }

    /// `value` is the CPU load from 0 to 1.
    func update(value: Double) {
        let v = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let number = Int((v * 100).rounded())
        text.string = "\(number)"
        let size = number >= 100 ? Self.smallFont.pointSize : Self.font.pointSize
        if text.fontSize != size { text.fontSize = size }
        fill.bounds.size.height = (Self.capsule.height * v).rounded()
        // From the number shown, so "50" is never green.
        let newLevel = Level(Double(number) / 100)
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
