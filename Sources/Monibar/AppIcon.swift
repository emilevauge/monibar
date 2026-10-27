import AppKit
import SwiftUI

/// The app icon: the menu bar chip, scaled up on a dark tile, its body
/// filled green from the bottom as on a calm Mac.
struct AppIconView: View {
    private static let side: CGFloat = 1024
    /// Menu bar points to icon pixels.
    private static let scale: CGFloat = 30

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
            Canvas { context, size in
                Self.drawChip(in: &context, center: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .frame(width: Self.side, height: Self.side)
    }

    /// Same geometry as `IconView`, white outline and pins.
    private static func drawChip(in context: inout GraphicsContext, center: CGPoint) {
        let s = scale
        let body = IconView.body * s
        let box = CGRect(x: center.x - body / 2, y: center.y - body / 2, width: body, height: body)
        let pinLength = IconView.pinLength * s
        let pinWidth = IconView.pinWidth * s
        let outline = IconView.outline * s
        let radius = IconView.cornerRadius * s

        for i in 0..<12 {
            let offset = CGFloat(i % 3 - 1) * IconView.pinSpacing * s - pinWidth / 2
            let pin = switch i / 3 {
            case 0: CGRect(x: box.minX - pinLength, y: box.midY + offset, width: pinLength, height: pinWidth)
            case 1: CGRect(x: box.maxX, y: box.midY + offset, width: pinLength, height: pinWidth)
            case 2: CGRect(x: box.midX + offset, y: box.minY - pinLength, width: pinWidth, height: pinLength)
            default: CGRect(x: box.midX + offset, y: box.maxY, width: pinWidth, height: pinLength)
            }
            context.fill(Path(pin), with: .color(.white))
        }

        let shape = Path(roundedRect: box, cornerRadius: radius, style: .continuous)
        let green = Color(nsColor: .systemGreen)
        context.fill(shape, with: .color(green.opacity(0.35)))
        let level = box.height * 0.45
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(Path(CGRect(x: box.minX, y: box.maxY - level, width: box.width, height: level)),
                       with: .color(green))
        }
        // Stroked inside the body, as a CALayer border is.
        context.stroke(Path(roundedRect: box.insetBy(dx: outline / 2, dy: outline / 2),
                            cornerRadius: radius - outline / 2, style: .continuous),
                       with: .color(.white), lineWidth: outline)
    }
}

enum AppIcon {
    /// Renders the icon at 1024 px as a PNG, for build.sh's .icns.
    @MainActor
    static func writePNG(to path: String) -> Bool {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
