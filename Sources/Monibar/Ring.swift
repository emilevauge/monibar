/// Fixed-size ring buffer of samples, oldest values overwritten first.
/// Used for the icon's averaging window.
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

    func mean(last n: Int) -> Float {
        let n = min(n, count)
        guard n > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<n { s += buf[(head - 1 - i + buf.count * 2) % buf.count] }
        return s / Float(n)
    }
}

/// Values over wall-clock time, each covering the interval since the
/// previous point: a rate computed from cumulated kernel counters, or a
/// reading. Points are 2 s apart while the panel is open and 1 min apart
/// while it is closed, so one series holds both.
struct TimeSeries {
    /// One hour of history, plus some slack so trimming runs in chunks.
    static let maxAge: Double = 3600
    private static let trimSlack: Double = 300

    private var starts: [Double] = []
    private var ends: [Double] = []
    private var values: [Float] = []

    mutating func add(_ v: Float, from start: Double, to end: Double) {
        guard end > start else { return }
        starts.append(start)
        ends.append(end)
        values.append(v)
        if let first = ends.first, end - first > Self.maxAge + Self.trimSlack {
            let k = ends.firstIndex { $0 >= end - Self.maxAge } ?? ends.count
            starts.removeFirst(k)
            ends.removeFirst(k)
            values.removeFirst(k)
        }
    }

    /// The last `window` seconds before `now` cut into `count` buckets,
    /// oldest first: the mean of each bucket weighted by the time each point
    /// covers in it, nil where nothing was measured (Mac asleep, app not
    /// running).
    func buckets(window: Double, count: Int, now: Double) -> [Float?] {
        guard count > 0, window > 0 else { return [] }
        let from = now - window
        let width = window / Double(count)
        var sums = [Double](repeating: 0, count: count)
        var weights = [Double](repeating: 0, count: count)

        // First point ending after `from`: points are in time order.
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= from { lo = mid + 1 } else { hi = mid }
        }
        for i in lo..<ends.count {
            let s = max(starts[i], from), e = min(ends[i], now)
            guard e > s else { continue }
            var b = min(count - 1, Int((s - from) / width))
            while b < count {
                let bs = from + Double(b) * width, be = bs + width
                let overlap = min(e, be) - max(s, bs)
                if overlap > 0 {
                    sums[b] += Double(values[i]) * overlap
                    weights[b] += overlap
                }
                if be >= e { break }
                b += 1
            }
        }
        return (0..<count).map { weights[$0] > 0 ? Float(sums[$0] / weights[$0]) : nil }
    }
}
