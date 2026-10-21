/// Fixed-size ring buffer of samples, oldest values overwritten first.
struct Ring {
    private var buf: [Float]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        buf = .init(repeating: 0, count: capacity)
    }

    mutating func push(_ v: Float) {
        buf[head] = v
        head = (head + 1) % buf.count
        count = min(count + 1, buf.count)
    }

    /// Value `i` steps back from the newest one (0 = newest).
    private func back(_ i: Int) -> Float {
        buf[(head - 1 - i + buf.count * 2) % buf.count]
    }

    func mean(last n: Int) -> Float {
        let n = min(n, count)
        guard n > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<n { s += back(i) }
        return s / Float(n)
    }

    /// Newest `n` values, oldest first, without downsampling.
    func tail(_ n: Int) -> [Float] {
        let n = min(n, count)
        return (0..<n).reversed().map(back)
    }

    /// Covers the last `window` samples with at most `points` bucket means, oldest first.
    /// When history is shorter than the window, fewer buckets are returned and
    /// the caller right-aligns them against `slots(window:points:)`.
    func series(window: Int, points: Int) -> [Float] {
        let slots = Ring.slots(window: window, points: points)
        let m = min(window, count)
        guard m > 0, slots > 0 else { return [] }
        let bucket = Double(window) / Double(slots)
        let outLen = min(slots, Int((Double(m) / bucket).rounded(.up)))
        var out = [Float](repeating: 0, count: outLen)
        for k in 0..<outLen {
            let lo = Int((Double(k) * bucket).rounded())
            let hi = min(m, max(lo + 1, Int((Double(k + 1) * bucket).rounded())))
            var s: Float = 0
            for i in lo..<hi { s += back(i) }
            out[outLen - 1 - k] = s / Float(hi - lo)
        }
        return out
    }

    static func slots(window: Int, points: Int) -> Int {
        min(window, points)
    }
}
