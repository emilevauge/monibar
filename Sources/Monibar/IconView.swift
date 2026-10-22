import AppKit

/// Menu bar icon: a CPU chip whose body fills from the bottom with the load,
/// green under 50 %, orange under 80 %, red above, three pins on each side
/// and the number in white on top. The digits are Calbar's: monospaced bold,
/// shrunk until they fit, centered on their cap height. Without Internet, the
/// body's outline turns to red dashes over white.
///
/// Built from CALayers, so an update only moves the fill edge and, when the
/// number changes, swaps the text: no image is redrawn.
final class IconView: NSView {
    private static let body: CGFloat = 14
    private static let pinLength: CGFloat = 2.2
    private static let pinWidth: CGFloat = 1.2
    private static let outline: CGFloat = 1.2
    /// Digits: start size and the width they must fit in.
    private static let fontSize: CGFloat = 8.5
    private static let maxTextWidth: CGFloat = 11.5
    static let size = NSSize(width: body + 2 * pinLength + 1, height: 22)

    private let track = CALayer()
    private let fill = CALayer()
    private let text = CATextLayer()
    private let alert = CAShapeLayer()
    private let pins = (0..<12).map { _ in CALayer() }
    private var level: Level?
    private var shownText = ""
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
            let offset = CGFloat(i % 3 - 1) * 4 - Self.pinWidth / 2
            pin.frame = switch i / 3 {
            case 0: CGRect(x: box.minX - Self.pinLength, y: box.midY + offset, width: Self.pinLength, height: Self.pinWidth)
            case 1: CGRect(x: box.maxX, y: box.midY + offset, width: Self.pinLength, height: Self.pinWidth)
            case 2: CGRect(x: box.midX + offset, y: box.maxY, width: Self.pinWidth, height: Self.pinLength)
            default: CGRect(x: box.midX + offset, y: box.minY - Self.pinLength, width: Self.pinWidth, height: Self.pinLength)
            }
            layer?.addSublayer(pin)
        }

        track.frame = box
        track.cornerRadius = 2.5
        track.masksToBounds = true
        track.borderWidth = Self.outline
        fill.anchorPoint = .zero
        fill.frame = CGRect(x: 0, y: 0, width: box.width, height: 0)
        track.addSublayer(fill)

        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        track.addSublayer(text)
        layer?.addSublayer(track)

        // Red dashes over a white outline: the white gaps keep them visible
        // even on a red chip.
        alert.frame = box
        alert.path = CGPath(roundedRect: CGRect(origin: .zero, size: box.size).insetBy(dx: 0.75, dy: 0.75),
                            cornerWidth: 2, cornerHeight: 2, transform: nil)
        alert.fillColor = nil
        alert.lineWidth = 1.5
        alert.lineDashPattern = [2, 1.5]
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
        applyInk()
        CATransaction.commit()
    }

    /// `value` is the CPU load from 0 to 1.
    func update(value: Double) {
        let v = min(1, max(0, value))
        let number = Int((v * 100).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setText("\(number)")
        fill.bounds.size.height = (Self.body * v).rounded()
        // From the number shown, so "50" is never green.
        let newLevel = Level(Double(number) / 100)
        if newLevel != level {
            level = newLevel
            applyColors(newLevel)
        }
        CATransaction.commit()
    }

    /// Calbar's digits: shrink by half points until the text fits, then
    /// place the baseline so the digits center on their cap height rather
    /// than on the line box.
    private func setText(_ s: String) {
        guard s != shownText else { return }
        shownText = s
        var size = Self.fontSize
        var font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        while (s as NSString).size(withAttributes: [.font: font]).width > Self.maxTextWidth, size > 6 {
            size -= 0.5
            font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        }
        text.font = font
        text.fontSize = size
        text.string = s
        let height = ceil(font.ascender - font.descender)
        let baseline = Self.body / 2 - font.capHeight / 2
        text.frame = CGRect(x: 0, y: baseline + font.ascender - height, width: Self.body, height: height)
    }

    /// Pins and outline in the menu bar's ink; the outline turns white under
    /// the alert's dashes.
    private func applyInk() {
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pins.forEach { $0.backgroundColor = ink }
        track.borderColor = offline ? NSColor.white.cgColor : ink
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
