import AppKit
import ServiceManagement

enum HistoryRange: Int, CaseIterable, Identifiable {
    case m1, m15, h1
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .m1: "1m"
        case .m15: "15m"
        case .h1: "1h"
        }
    }

    var seconds: Double {
        switch self {
        case .m1: 60
        case .m15: 900
        case .h1: 3600
        }
    }
}

/// Windows the process list can average CPU over, in seconds.
enum ProcWindow {
    static let options: [(Int, String)] = [(10, "10s"), (60, "1m"), (3600, "1h"), (86400, "1j")]
}

struct ProcRow: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double
    let mem: UInt64
    let count: Int
    let isApp: Bool
    let icon: NSImage?

    static func == (a: ProcRow, b: ProcRow) -> Bool {
        a.id == b.id && a.name == b.name && a.cpu == b.cpu && a.mem == b.mem && a.count == b.count
    }
}

/// Graph points, oldest first, nil where nothing was measured.
struct Series {
    var values: [Float?] = []
}

/// What the panel shows. Everything here runs only while the panel is open:
/// a closed panel costs one CPU reading per tick, for the icon.
@MainActor
final class PanelModel: ObservableObject {
    static let graphPoints = 120
    static let rowCount = 10

    @Published private(set) var cpuUser = 0.0
    @Published private(set) var cpuSys = 0.0
    @Published private(set) var cores: [Double] = []
    @Published private(set) var gpu: Double?
    @Published private(set) var mem = MemInfo()
    @Published private(set) var netIn = 0.0
    @Published private(set) var netOut = 0.0
    @Published private(set) var diskRead = 0.0
    @Published private(set) var diskWrite = 0.0
    @Published private(set) var diskSpace: (free: Int64, total: Int64)?
    @Published private(set) var load: [Double] = []

    @Published private(set) var hTotal = Series()
    @Published private(set) var hUser = Series()
    @Published private(set) var hGPU = Series()
    @Published private(set) var hMem = Series()
    @Published private(set) var hNetIn = Series()
    @Published private(set) var hNetOut = Series()
    @Published private(set) var hDiskR = Series()
    @Published private(set) var hDiskW = Series()

    @Published private(set) var rows: [ProcRow] = []
    @Published private(set) var hiddenProcs = 0
    @Published var message: String?
    /// A newer release, offered in the settings menu.
    @Published private(set) var update: GitHubRelease?

    @Published var range: HistoryRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "historyRange"); refreshHistory() }
    }
    @Published var groupApps: Bool {
        didSet { UserDefaults.standard.set(groupApps, forKey: "groupApps"); rebuildRows() }
    }
    @Published var sortByMemory: Bool {
        didSet { UserDefaults.standard.set(sortByMemory, forKey: "sortByMemory"); rebuildRows() }
    }
    /// Seconds the process list averages CPU over: a longer window keeps
    /// the ranking steady.
    @Published var procWindow: Int {
        didSet { UserDefaults.standard.set(procWindow, forKey: "procWindow"); if visible { refreshProcesses() } }
    }
    @Published var iconWindow: Int {
        didSet { UserDefaults.standard.set(iconWindow, forKey: "iconWindow"); onIconWindowChange?() }
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    var onIconWindowChange: (() -> Void)?

    private let sampler: SystemSampler
    private let procSampler = ProcessSampler()
    private var lastProcs: [ProcSample] = []
    private var appCache: [pid_t: (name: String, icon: NSImage)?] = [:]
    private var messageTimer: Timer?
    private(set) var visible = false

    init(sampler: SystemSampler) {
        self.sampler = sampler
        let d = UserDefaults.standard
        range = HistoryRange(rawValue: d.object(forKey: "historyRange") as? Int ?? -1) ?? .m15
        groupApps = d.object(forKey: "groupApps") as? Bool ?? true
        sortByMemory = d.bool(forKey: "sortByMemory")
        iconWindow = d.object(forKey: "iconWindow") as? Int ?? 2
        let window = d.object(forKey: "procWindow") as? Int
        procWindow = ProcWindow.options.contains { $0.0 == window } ? window! : 10
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setVisible(_ v: Bool) {
        visible = v
        if v {
            update = UpdateChecker.available
            sampler.sampleOthers(withCores: true)
            refreshSystem()
            refreshHistory()
            lastProcs = procSampler.sample(window: TimeInterval(procWindow))
            rebuildRows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.visible else { return }
                self.sampler.sampleOthers(withCores: true)
                self.refreshSystem()
                self.refreshHistory()
                self.refreshProcesses()
            }
        } else {
            procSampler.panelClosed()
            lastProcs = []
            appCache.removeAll()
        }
    }

    /// Called once a minute: feeds the 1 h and 1 d averages of the process
    /// list, and the history of the graphs while the panel is closed.
    func minuteTick() {
        procSampler.takeSnapshot()
        // While open, the panel samples every tick already.
        if !visible { sampler.sampleOthers(withCores: false) }
    }

    /// Called after each sampler tick.
    func tick() {
        guard visible else { return }
        sampler.sampleOthers(withCores: true)
        refreshSystem()
        refreshHistory()
        refreshProcesses()
    }

    private func refreshSystem() {
        cpuUser = sampler.cpuUser
        cpuSys = sampler.cpuSys
        cores = sampler.cores
        gpu = sampler.gpu
        mem = sampler.mem
        netIn = sampler.netIn
        netOut = sampler.netOut
        diskRead = sampler.diskRead
        diskWrite = sampler.diskWrite
        diskSpace = SystemSampler.diskSpace()
        load = SystemSampler.loadAverage()
    }

    private func refreshHistory() {
        let now = Date().timeIntervalSinceReferenceDate
        func s(_ t: TimeSeries) -> Series {
            Series(values: t.buckets(window: range.seconds, count: Self.graphPoints, now: now))
        }
        hTotal = s(sampler.hCPU)
        hUser = s(sampler.hUser)
        hGPU = s(sampler.hGPU)
        hMem = s(sampler.hMem)
        hNetIn = s(sampler.hNetIn)
        hNetOut = s(sampler.hNetOut)
        hDiskR = s(sampler.hDiskR)
        hDiskW = s(sampler.hDiskW)
    }

    private func refreshProcesses() {
        lastProcs = procSampler.sample(window: TimeInterval(procWindow))
        rebuildRows()
    }

    private func rebuildRows() {
        hiddenProcs = max(0, procSampler.total - lastProcs.count)

        var built: [ProcRow]
        if groupApps {
            var groups: [pid_t: (cpu: Double, mem: UInt64, count: Int)] = [:]
            var names: [pid_t: String] = [:]
            for p in lastProcs {
                var g = groups[p.responsible] ?? (0, 0, 0)
                g.cpu += p.cpu
                g.mem += p.mem
                g.count += 1
                groups[p.responsible] = g
                if p.pid == p.responsible { names[p.pid] = p.name }
            }
            built = groups.map { pid, g in
                let app = appInfo(pid)
                return ProcRow(id: pid, name: app?.name ?? names[pid] ?? "pid \(pid)",
                               cpu: g.cpu, mem: g.mem, count: g.count,
                               isApp: app != nil, icon: app?.icon)
            }
        } else {
            built = lastProcs.map {
                ProcRow(id: $0.pid, name: $0.name, cpu: $0.cpu, mem: $0.mem, count: 1, isApp: false, icon: nil)
            }
        }
        if sortByMemory {
            built.sort { $0.mem > $1.mem }
        } else {
            built.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.mem > $1.mem }
        }
        let top = Array(built.prefix(Self.rowCount))
        if top != rows { rows = top }
    }

    private func appInfo(_ pid: pid_t) -> (name: String, icon: NSImage)? {
        if let cached = appCache[pid] { return cached }
        var info: (name: String, icon: NSImage)?
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
            icon.size = NSSize(width: 16, height: 16)
            info = (name, icon)
        }
        appCache[pid] = info
        return info
    }

    // MARK: Actions

    func kill(_ row: ProcRow, force: Bool) {
        var ok: Bool
        var reason = ""
        if row.isApp, let app = NSRunningApplication(processIdentifier: row.id) {
            ok = force ? app.forceTerminate() : app.terminate()
            if !ok { reason = "l'app a refusé" }
        } else {
            ok = Darwin.kill(row.id, force ? SIGKILL : SIGTERM) == 0
            if !ok { reason = errno == EPERM ? "permission refusée" : String(cString: strerror(errno)) }
        }
        flash(ok ? "\(force ? "Forcé" : "Quitté") : \(row.name)" : "Échec sur \(row.name) : \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.visible else { return }
            self.appCache[row.id] = nil
            self.refreshProcesses()
        }
    }

    func checkForUpdates() {
        Task { @MainActor in
            switch await UpdateChecker.checkManually() {
            case .upToDate(let current): flash("Monibar \(current) est à jour")
            case .newer(let release):
                update = release
                flash("Monibar \(release.version) est disponible")
            case .error(let message): flash(message)
            }
        }
    }

    /// Downloads the DMG and relaunches, or opens the release page when
    /// the release has no DMG.
    func installUpdate() {
        guard let update else { return }
        guard let dmg = update.dmgURL else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        flash("Téléchargement de Monibar \(update.version)…")
        UpdateChecker.install(dmgURL: dmg)
    }

    private func flash(_ text: String) {
        message = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.message = nil }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            flash("Démarrage auto : \(error.localizedDescription)")
        }
    }
}
