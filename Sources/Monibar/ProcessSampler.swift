import AppKit
import Darwin

/// Private but stable libsystem call: the process macOS holds responsible for `pid`
/// (e.g. the browser for its helper processes). Activity Monitor relies on it too.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t

struct ProcSample {
    let pid: pid_t
    /// Percent of one core, can exceed 100 like in Activity Monitor.
    let cpu: Double
    let mem: UInt64
    let responsible: pid_t
}

/// Cumulated CPU time of every readable process at one instant, sorted by pid.
/// The kernel counts CPU time since each process started, so the average over
/// a window is the difference with the snapshot taken at its start.
private struct Snapshot {
    let at: UInt64
    var pids: [pid_t] = []
    var starts: [UInt64] = []
    var cpus: [UInt64] = []

    /// A copy sized to its content: the scan reserves room for unreadable
    /// processes too, about a third more.
    func compacted() -> Snapshot {
        Snapshot(at: at, pids: Self.exact(pids), starts: Self.exact(starts), cpus: Self.exact(cpus))
    }

    /// A copy with capacity equal to its count. `Array(a[...])` may share
    /// the original, oversized buffer.
    private static func exact<T>(_ a: [T]) -> [T] {
        [T](unsafeUninitializedCapacity: a.count) { buffer, count in
            _ = buffer.initialize(from: a)
            count = a.count
        }
    }

    func index(of pid: pid_t) -> Int? {
        var lo = 0, hi = pids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pids[mid] < pid { lo = mid + 1 } else { hi = mid }
        }
        return lo < pids.count && pids[lo] == pid ? lo : nil
    }
}

/// Per-process CPU and memory. With the panel closed, only a snapshot of CPU
/// counters is taken once a minute (about 1 ms). Snapshots are kept 10 min
/// at that pace, 1 h at one per 5 min and 24 h at one per 15 min, so the
/// list can average over up to a day; about 120 snapshots of ~10 KB.
/// Processes owned by other users (root daemons) are not readable without
/// privileges and are skipped.
final class ProcessSampler {
    static let snapshotInterval: TimeInterval = 60

    private struct Meta {
        var start: UInt64
        /// Looked up only for the rows shown, see `name(of:)`.
        var name: String?
        var responsible: pid_t
    }

    /// Panel ticks, kept a little over the shortest window.
    private var recent: [Snapshot] = []
    private var minutes: [Snapshot] = []
    private var fives: [Snapshot] = []
    private var quarters: [Snapshot] = []
    private var meta: [pid_t: Meta] = [:]
    private var pids = [pid_t](repeating: 0, count: 2048)
    private let ticksPerSecond: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()
    /// Process count from the last scan, readable or not.
    private(set) var total = 0

    /// Called once a minute, panel open or not.
    func takeSnapshot() {
        let snap = scan(withMemory: false).snapshot.compacted()
        func keep(_ list: inout [Snapshot], every: Double, count: Int) {
            guard list.last.map({ seconds(snap.at - $0.at) >= every - 5 }) ?? true else { return }
            list.append(snap)
            if list.count > count { list.removeFirst() }
        }
        keep(&minutes, every: 60, count: 11)
        keep(&fives, every: 5 * 60, count: 13)
        keep(&quarters, every: 15 * 60, count: 97)
    }

    /// Frees what only the panel needs.
    func panelClosed() {
        recent.removeAll()
        meta.removeAll()
    }

    /// CPU averaged over the last `window` seconds, or over the history
    /// available when shorter.
    func sample(window: TimeInterval) -> [ProcSample] {
        let (now, mems) = scan(withMemory: true)
        let base = baseline(for: now.at, window: window)
        recent.append(now)
        recent.removeAll { seconds(now.at - $0.at) > 12 }

        var out = [ProcSample]()
        out.reserveCapacity(now.pids.count)
        var seen = Set<pid_t>(minimumCapacity: now.pids.count)
        for i in now.pids.indices {
            let pid = now.pids[i]
            let start = now.starts[i]
            var m: Meta
            if let cached = meta[pid], cached.start == start {
                m = cached
            } else {
                m = Meta(start: start, name: nil, responsible: responsiblePid(pid))
                meta[pid] = m
            }
            seen.insert(pid)

            var cpu = 0.0
            if let base {
                // rusage times and mach_absolute_time share the same tick
                // unit, so the ratio needs no timebase conversion.
                let span = Double(now.at - base.at)
                if let j = base.index(of: pid), base.starts[j] == start {
                    if now.cpus[i] >= base.cpus[j] { cpu = Double(now.cpus[i] - base.cpus[j]) / span * 100 }
                } else if start > base.at {
                    // Started inside the window: all its CPU time counts.
                    cpu = Double(now.cpus[i]) / span * 100
                }
            }
            out.append(ProcSample(pid: pid, cpu: cpu, mem: mems[i],
                                  responsible: m.responsible > 0 ? m.responsible : pid))
        }
        // Exited processes: a panel left open for days would keep them all.
        if meta.count > seen.count + 64 { meta = meta.filter { seen.contains($0.key) } }
        return out
    }

    /// The newest snapshot at least `window` old, else the oldest one.
    private func baseline(for now: UInt64, window: TimeInterval) -> Snapshot? {
        let target = now &- UInt64(window * ticksPerSecond)
        var best: Snapshot?
        var oldest: Snapshot?
        for list in [quarters, fives, minutes, recent] {
            for s in list where s.at < now {
                if oldest == nil || s.at < oldest!.at { oldest = s }
                if s.at <= target, best == nil || s.at > best!.at { best = s }
            }
        }
        return best ?? oldest
    }

    private func scan(withMemory: Bool) -> (snapshot: Snapshot, mems: [UInt64]) {
        var n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        while n >= pids.count {
            pids = [pid_t](repeating: 0, count: pids.count * 2)
            n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        }
        var snap = Snapshot(at: mach_absolute_time())
        var mems = [UInt64]()
        guard n > 0 else { return (snap, mems) }
        total = n
        pids[0..<n].sort()
        snap.pids.reserveCapacity(n)
        snap.starts.reserveCapacity(n)
        snap.cpus.reserveCapacity(n)
        if withMemory { mems.reserveCapacity(n) }

        var ri = rusage_info_v4()
        for pid in pids[0..<n] where pid > 0 {
            let rc = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            snap.pids.append(pid)
            snap.starts.append(ri.ri_proc_start_abstime)
            snap.cpus.append(ri.ri_user_time + ri.ri_system_time)
            if withMemory { mems.append(ri.ri_phys_footprint) }
        }
        return (snap, mems)
    }

    private func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) / ticksPerSecond
    }

    /// Executable name, cached until the process exits. Only the displayed
    /// rows need one: looking up all ~800 paths at each panel opening cost
    /// several ms.
    func name(of pid: pid_t) -> String {
        if let name = meta[pid]?.name { return name }
        let name = Self.lookUpName(pid)
        meta[pid]?.name = name
        return name
    }

    private static func lookUpName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let last = path.split(separator: "/").last { return String(last) }
        }
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return "pid \(pid)"
    }
}
