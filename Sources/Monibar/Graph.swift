import SwiftUI

struct GraphLayer {
    let series: Series
    let color: Color
    var fill = true
}

/// Area graph drawn with Canvas: one path per layer, no per-point views.
struct Graph: View {
    let layers: [GraphLayer]
    /// Fixed top of the scale. When nil, scales to the largest value seen.
    var maxValue: Float?
    var minScale: Float = 0
    /// Draws the second layer downward from the middle line (network, disk).
    var mirrored = false
    var height: CGFloat = 44

    var body: some View {
        Canvas { ctx, size in
            let top = scaleTop()
            if mirrored, layers.count == 2 {
                let mid = size.height / 2
                draw(layers[0], in: &ctx, width: size.width, base: mid, span: -mid, top: top)
                draw(layers[1], in: &ctx, width: size.width, base: mid, span: mid, top: top)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid))
                line.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            } else {
                for l in layers {
                    draw(l, in: &ctx, width: size.width, base: size.height, span: -size.height, top: top)
                }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func scaleTop() -> Float {
        if let maxValue { return maxValue }
        var m = minScale
        for l in layers { for v in l.series.values where v > m { m = v } }
        return m > 0 ? m * 1.1 : 1
    }

    private func draw(_ layer: GraphLayer, in ctx: inout GraphicsContext,
                      width: CGFloat, base: CGFloat, span: CGFloat, top: Float) {
        let values = layer.series.values
        let slots = max(layer.series.slots, 2)
        guard !values.isEmpty else { return }
        let step = width / CGFloat(slots - 1)
        let first = slots - values.count
        func pt(_ i: Int) -> CGPoint {
            let v = CGFloat(min(values[i], top) / top)
            return CGPoint(x: CGFloat(first + i) * step, y: base + span * v)
        }
        var line = Path()
        line.move(to: pt(0))
        for i in 1..<values.count { line.addLine(to: pt(i)) }
        if layer.fill {
            var area = line
            area.addLine(to: CGPoint(x: pt(values.count - 1).x, y: base))
            area.addLine(to: CGPoint(x: pt(0).x, y: base))
            area.closeSubpath()
            ctx.fill(area, with: .color(layer.color.opacity(0.35)))
        }
        ctx.stroke(line, with: .color(layer.color), lineWidth: 1)
    }
}

/// Horizontal bar split in colored segments, values as fractions of the whole.
struct SegmentBar: View {
    let segments: [(value: Double, color: Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color)
                        .frame(width: max(0, geo.size.width * segments[i].value - 1))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(.quaternary.opacity(0.5))
        .clipShape(Capsule())
    }
}

/// One thin vertical bar per core.
struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores.indices, id: \.self) { i in
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color.blue)
                            .frame(height: max(1, geo.size.height * cores[i]))
                    }
                }
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
        }
        .frame(height: 16)
    }
}
