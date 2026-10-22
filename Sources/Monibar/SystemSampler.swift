import Darwin
import Foundation
import IOKit

struct MemInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure: Int32 = 1

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
    private var prevTicks: [UInt32] = []
    private var prevTotalTicks: [UInt32] = []
    private var prevCPUTime: Double = 0
    private var prevNet: (rx: UInt64, tx: UInt64)?
    private var prevDisk: (r: UInt64, w: UInt64)?
    private var prevTime: Double = 0
    private var netBuf = [UInt8]()
    private var netIncluded: [UInt16: Bool] = [:]
    private var diskDrivers: [io_service_t] = []
    private var gpuService: io_service_t = 0
    private var samples = 0

    private(set) var cores: [Double] = []
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

    private static var now: Double { Date().timeIntervalSinceReferenceDate }

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
        let now = Self.now
        let since = prevCPUTime
        prevCPUTime = now
        let t = load.cpu_ticks
        let cur = [t.0, t.1, t.2, t.3] // user, system, idle, nice
        defer { prevTotalTicks = cur }
        guard prevTotalTicks.count == 4 else { return }
        // 32-bit tick counters wrap, wrapping subtraction keeps deltas right.
        let d = (0..<4).map { UInt64(cur[$0] &- prevTotalTicks[$0]) }
        let all = d.reduce(0, +)
        guard all > 0 else { return }
        cpuUser = Double(d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]) / Double(all)
        cpuSys = Double(d[Int(CPU_STATE_SYSTEM)]) / Double(all)
        recentCPU.push(Float(cpuTotal))
        guard now - since <= Self.maxCPUGap else { return }
        hUser.add(Float(cpuUser), from: since, to: now)
        hCPU.add(Float(cpuTotal), from: since, to: now)
    }

    /// Memory, network, disk and GPU; per-core CPU too while the panel is
    /// open. Called every tick with the panel open, once a minute otherwise.
    func sampleOthers(withCores: Bool) {
        let now = Self.now
        let dt = prevTime > 0 ? now - prevTime : 0
        let since = prevTime
        prevTime = now
        let record = dt > 0 && dt <= Self.maxGap

        if withCores { sampleCores() } else { prevTicks = [] }
        sampleMemory()

        let net = readNet()
        if let p = prevNet, dt > 0, net.rx >= p.rx, net.tx >= p.tx {
            netIn = Double(net.rx - p.rx) / dt
            netOut = Double(net.tx - p.tx) / dt
        }
        prevNet = net

        if samples % 30 == 0 { refreshDiskDrivers() }
        let disk = readDisk()
        if let p = prevDisk, dt > 0, disk.r >= p.r, disk.w >= p.w {
            diskRead = Double(disk.r - p.r) / dt
            diskWrite = Double(disk.w - p.w) / dt
        }
        prevDisk = disk

        gpu = readGPU()
        samples += 1
        guard record else { return }

        hMem.add(mem.total > 0 ? Float(Double(mem.used) / Double(mem.total)) : 0, from: since, to: now)
        hNetIn.add(Float(netIn), from: since, to: now)
        hNetOut.add(Float(netOut), from: since, to: now)
        hDiskR.add(Float(diskRead), from: since, to: now)
        hDiskW.add(Float(diskWrite), from: since, to: now)
        if let gpu { hGPU.add(Float(gpu), from: since, to: now) }
    }

    // MARK: CPU

    private func sampleCores() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let n = Int(count)
        let stride = Int(CPU_STATE_MAX)
        var cur = [UInt32](repeating: 0, count: n * stride)
        for i in 0..<n * stride { cur[i] = UInt32(bitPattern: info[i]) }
        defer { prevTicks = cur }
        guard prevTicks.count == cur.count else { return }

        var newCores = [Double](repeating: 0, count: n)
        for c in 0..<n {
            let b = c * stride
            // 32-bit tick counters wrap, wrapping subtraction keeps deltas right.
            let user = UInt64(cur[b + Int(CPU_STATE_USER)] &- prevTicks[b + Int(CPU_STATE_USER)])
            let nice = UInt64(cur[b + Int(CPU_STATE_NICE)] &- prevTicks[b + Int(CPU_STATE_NICE)])
            let sys = UInt64(cur[b + Int(CPU_STATE_SYSTEM)] &- prevTicks[b + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(cur[b + Int(CPU_STATE_IDLE)] &- prevTicks[b + Int(CPU_STATE_IDLE)])
            let all = user + nice + sys + idle
            newCores[c] = all > 0 ? Double(user + nice + sys) / Double(all) : 0
        }
        cores = newCores
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
        mem.app = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
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
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            mem.pressure = level
        }
    }

    // MARK: Network

    /// 64-bit interface counters through NET_RT_IFLIST2 (getifaddrs only has 32-bit ones).
    private func readNet() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        if netBuf.count < len { netBuf = [UInt8](repeating: 0, count: len + 1024) }
        guard sysctl(&mib, 6, &netBuf, &len, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        netBuf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if includeInterface(h2.ifm_index) {
                        rx += h2.ifm_data.ifi_ibytes
                        tx += h2.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (rx, tx)
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

    private func readDisk() -> (r: UInt64, w: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        for s in diskDrivers {
            guard let stats = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary else { continue }
            r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
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
