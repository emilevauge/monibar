import Darwin
import Foundation
import IOKit

struct MemInfo: Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var used: UInt64 { app + wired + compressed }
}

/// Collects system-wide metrics. Every read is a direct Mach, sysctl or IOKit
/// call: no subprocess, no polling of /usr/bin tools.
///
/// The total CPU is read every 2 s for the icon. The other metrics are read
/// every 2 s while the panel is open and once a minute while it is closed.
/// Network, disk and CPU come from counters the kernel cumulates since boot,
/// so a minute point is the exact average of that minute; memory and GPU are
/// readings, one per point.
final class SystemSampler {
    static let interval: TimeInterval = 2
    /// Points further apart than this span a sleep or a stall: they are not
    /// recorded, the graph shows a gap there.
    private static let maxCPUGap: Double = 10
    private static let maxGap: Double = 150

    private let host = mach_host_self()
    private var prevTotalTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var prevCPU: Stamp?
    /// Per interface and per disk: one going away or coming back must not
    /// change the sum by its whole count.
    private var prevNet: [UInt16: (rx: UInt64, tx: UInt64)] = [:]
    private var prevDisk: [UInt64: (r: UInt64, w: UInt64)] = [:]
    private var prevOthers: Stamp?
    private var netBuf = [UInt8]()
    private var netIncluded: [UInt16: Bool] = [:]
    private var diskDrivers: [io_service_t] = []
    private var gpuService: io_service_t = 0
    private var samples = 0

    private(set) var cpuUser = 0.0
    private(set) var cpuSys = 0.0
    private(set) var mem = MemInfo()
    private(set) var netIn = 0.0
    private(set) var netOut = 0.0
    private(set) var diskRead = 0.0
    private(set) var diskWrite = 0.0
    private(set) var gpu: Double?

    private(set) var hUser = TimeSeries()
    private(set) var hCPU = TimeSeries()
    private(set) var hMem = TimeSeries()
    private(set) var hNetIn = TimeSeries()
    private(set) var hNetOut = TimeSeries()
    private(set) var hDiskR = TimeSeries()
    private(set) var hDiskW = TimeSeries()
    private(set) var hGPU = TimeSeries()
    /// User + system for the icon's averaging window, up to 60 s.
    private(set) var recentCPU = Ring(capacity: 30)

    var cpuTotal: Double { cpuUser + cpuSys }

    /// Wall time places a point on the graphs; uptime, which stops while
    /// the Mac sleeps and never goes back, measures how long it covers.
    private struct Stamp {
        let wall: Double
        let uptime: Double

        static var now: Stamp {
            Stamp(wall: Date().timeIntervalSinceReferenceDate, uptime: ProcessInfo.processInfo.systemUptime)
        }

        /// Seconds since `earlier`, nil when the Mac slept or the clock was
        /// changed in between: the two clocks then disagree.
        func interval(since earlier: Stamp, max: Double) -> Double? {
            let dt = uptime - earlier.uptime
            guard dt > 0, dt <= max, abs((wall - earlier.wall) - dt) < 2 else { return nil }
            return dt
        }
    }

    /// Every tick: total CPU only, one Mach call.
    func sampleCPU() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let now = Stamp.now
        let since = prevCPU
        prevCPU = now
        let t = load.cpu_ticks
        let cur = (user: UInt32(t.0), system: UInt32(t.1), idle: UInt32(t.2), nice: UInt32(t.3))
        defer { prevTotalTicks = cur }
        guard let p = prevTotalTicks else { return }
        // 32-bit tick counters wrap, wrapping subtraction keeps deltas right.
        let user = UInt64(cur.user &- p.user) + UInt64(cur.nice &- p.nice)
        let system = UInt64(cur.system &- p.system)
        let all = user + system + UInt64(cur.idle &- p.idle)
        guard all > 0 else { return }
        cpuUser = Double(user) / Double(all)
        cpuSys = Double(system) / Double(all)
        recentCPU.push(Float(cpuTotal))
        guard let since, now.interval(since: since, max: Self.maxCPUGap) != nil else { return }
        hUser.add(Float(cpuUser), from: since.wall, to: now.wall)
        hCPU.add(Float(cpuTotal), from: since.wall, to: now.wall)
    }

    /// Memory, network, disk and GPU. Called every tick with the panel open,
    /// once a minute otherwise.
    func sampleOthers() {
        let now = Stamp.now
        let since = prevOthers
        prevOthers = now
        // nil after a sleep, a clock change or the first call: the rates
        // are then reset and nothing is recorded.
        let dt = since.flatMap { now.interval(since: $0, max: Self.maxGap) }

        sampleMemory()

        let net = readNet()
        let (rx, tx) = Self.growth(from: prevNet, to: net) { ($0.rx, $0.tx) }
        prevNet = net
        netIn = dt.map { Double(rx) / $0 } ?? 0
        netOut = dt.map { Double(tx) / $0 } ?? 0

        if samples % 30 == 0 { refreshDiskDrivers() }
        let disk = readDisk()
        let (r, w) = Self.growth(from: prevDisk, to: disk) { ($0.r, $0.w) }
        prevDisk = disk
        diskRead = dt.map { Double(r) / $0 } ?? 0
        diskWrite = dt.map { Double(w) / $0 } ?? 0

        gpu = readGPU()
        samples += 1
        guard let since, dt != nil else { return }

        let (from, to) = (since.wall, now.wall)
        hMem.add(mem.total > 0 ? Float(Double(mem.used) / Double(mem.total)) : 0, from: from, to: to)
        hNetIn.add(Float(netIn), from: from, to: to)
        hNetOut.add(Float(netOut), from: from, to: to)
        hDiskR.add(Float(diskRead), from: from, to: to)
        hDiskW.add(Float(diskWrite), from: from, to: to)
        if let gpu { hGPU.add(Float(gpu), from: from, to: to) }
    }

    /// Bytes added since `previous`, summed over the counters present both
    /// times: a new interface or disk brings none of its past bytes, and a
    /// counter that went back (reset) adds nothing.
    private static func growth<K: Hashable, V>(from previous: [K: V], to current: [K: V],
                                               _ pair: (V) -> (UInt64, UInt64)) -> (UInt64, UInt64) {
        var a: UInt64 = 0, b: UInt64 = 0
        for (key, value) in current {
            guard let old = previous[key] else { continue }
            let (x, y) = pair(value), (ox, oy) = pair(old)
            if x >= ox { a += x - ox }
            if y >= oy { b += y - oy }
        }
        return (a, b)
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)
        if mem.total == 0 {
            var total: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            sysctlbyname("hw.memsize", &total, &size, nil, 0)
            mem.total = total
        }
        // Same split as Activity Monitor.
        // The counters are not read atomically: never let purgeable exceed
        // internal and trap.
        let internalPages = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        mem.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        mem.wired = UInt64(stats.wire_count) * page
        mem.compressed = UInt64(stats.compressor_page_count) * page
        mem.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        mem.free = mem.total > mem.used + mem.cached ? mem.total - mem.used - mem.cached : 0

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            mem.swapUsed = swap.xsu_used
            mem.swapTotal = swap.xsu_total
        }
    }

    // MARK: Network

    /// 64-bit interface counters through NET_RT_IFLIST2 (getifaddrs only has 32-bit ones).
    /// Byte counters of the physical interfaces, by interface index.
    private func readNet() -> [UInt16: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        if netBuf.count < len { netBuf = [UInt8](repeating: 0, count: len + 1024) }
        guard sysctl(&mib, 6, &netBuf, &len, nil, 0) == 0 else { return [:] }

        var counters: [UInt16: (rx: UInt64, tx: UInt64)] = [:]
        var seen = Set<UInt16>()
        netBuf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    seen.insert(h2.ifm_index)
                    if includeInterface(h2.ifm_index) {
                        counters[h2.ifm_index] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        // macOS reuses the index of a removed interface: forget the decision
        // so a VPN tunnel taking an old en index is not counted.
        if netIncluded.count > seen.count { netIncluded = netIncluded.filter { seen.contains($0.key) } }
        return counters
    }

    /// Physical interfaces only: VPN tunnels (utun) would count the same traffic twice.
    private func includeInterface(_ index: UInt16) -> Bool {
        if let v = netIncluded[index] { return v }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return false }
        let s = String(cString: name)
        let v = s.hasPrefix("en") || s.hasPrefix("pdp_ip")
        netIncluded[index] = v
        return v
    }

    // MARK: Disk

    private func refreshDiskDrivers() {
        diskDrivers.forEach { IOObjectRelease($0) }
        diskDrivers.removeAll()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while true {
            let s = IOIteratorNext(iter)
            if s == 0 { break }
            diskDrivers.append(s)
        }
    }

    /// Byte counters by disk driver, keyed by registry entry id.
    private func readDisk() -> [UInt64: (r: UInt64, w: UInt64)] {
        var counters: [UInt64: (r: UInt64, w: UInt64)] = [:]
        for s in diskDrivers {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(s, &id) == KERN_SUCCESS,
                  let stats = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSDictionary else { continue }
            counters[id] = ((stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                            (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
        }
        return counters
    }

    // MARK: GPU

    private func readGPU() -> Double? {
        if gpuService == 0 {
            gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        }
        guard gpuService != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary,
              let u = stats["Device Utilization %"] as? NSNumber else { return nil }
        return min(1, u.doubleValue / 100)
    }

    // MARK: On-demand reads (panel only)

    static func diskSpace() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }
}
