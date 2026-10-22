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
struct Series: Equatable {
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
    @Published private(set) var hInternet = Series()
    @Published private(set) var hDiskR = Series()
    @Published private(set) var hDiskW = Series()

    @Published private(set) var rows: [ProcRow] = []
    @Published private(set) var hiddenProcs = 0
    @Published var message: String?
    @Published private(set) var internet = Connectivity.State.unknown
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
    private let connectivity = Connectivity()
    private var lastProcs: [ProcSample] = []
    private var diskSpaceAt = Date.distantPast
    /// App name and icon by pid, for the rows shown. A pid that is not an
    /// app yet (launching) is looked up again after 10 s.
    private var appCache: [pid_t: (info: (name: String, icon: NSImage)?, at: Date)] = [:]
    private var followUp: DispatchWorkItem?
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
        connectivity.onChange = { [weak self] in self?.internet = $0 }
        connectivity.start()
    }

    func setVisible(_ v: Bool) {
        visible = v
        if v {
            internet = connectivity.state
            diskSpaceAt = .distantPast
            connectivity.probe()
            update = UpdateChecker.available
            sampler.sampleOthers()
            refreshSystem()
            refreshHistory()
            lastProcs = procSampler.sample(window: TimeInterval(procWindow))
            rebuildRows()
            // A second pass soon after, for rates over a real interval.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.visible else { return }
                self.sampler.sampleOthers()
                self.refreshSystem()
                self.refreshHistory()
                self.refreshProcesses()
            }
            followUp?.cancel()
            followUp = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            followUp?.cancel()
            followUp = nil
            procSampler.panelClosed()
            lastProcs = []
            appCache.removeAll()
        }
    }

    /// Called once a minute: feeds the 1 h and 1 d averages of the process
    /// list, and the history of the graphs while the panel is closed.
    func minuteTick() {
        procSampler.takeSnapshot()
        connectivity.probe()
        // While open, the panel samples every tick already.
        if !visible { sampler.sampleOthers() }
    }

    /// Called after each sampler tick.
    func tick() {
        guard visible else { return }
        sampler.sampleOthers()
        refreshSystem()
        refreshHistory()
        refreshProcesses()
    }

    private func refreshSystem() {
        // Assigned only when changed: each assignment invalidates the view.
        set(\.cpuUser, sampler.cpuUser)
        set(\.cpuSys, sampler.cpuSys)
        set(\.gpu, sampler.gpu)
        set(\.mem, sampler.mem)
        set(\.netIn, sampler.netIn)
        set(\.netOut, sampler.netOut)
        set(\.diskRead, sampler.diskRead)
        set(\.diskWrite, sampler.diskWrite)
        set(\.load, SystemSampler.loadAverage())
        refreshDiskSpace()
    }

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<PanelModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// The free space query computes purgeable space and costs about 6 ms:
    /// run off the main thread, at most once a minute.
    private func refreshDiskSpace() {
        let now = Date()
        guard now.timeIntervalSince(diskSpaceAt) >= 60 else { return }
        diskSpaceAt = now
        Task.detached(priority: .utility) {
            let space = SystemSampler.diskSpace()
            await MainActor.run { self.diskSpace = space }
        }
    }

    private func refreshHistory() {
        let now = Date().timeIntervalSinceReferenceDate
        func s(_ t: TimeSeries) -> Series {
            Series(values: t.buckets(window: range.seconds, count: Self.graphPoints, now: now))
        }
        set(\.hTotal, s(sampler.hCPU))
        set(\.hUser, s(sampler.hUser))
        set(\.hGPU, s(sampler.hGPU))
        set(\.hMem, s(sampler.hMem))
        set(\.hNetIn, s(sampler.hNetIn))
        set(\.hNetOut, s(sampler.hNetOut))
        set(\.hInternet, Series(values: connectivity.history.buckets(window: range.seconds, count: Self.graphPoints,
                                                                      now: now, lowest: true)))
        set(\.hDiskR, s(sampler.hDiskR))
        set(\.hDiskW, s(sampler.hDiskW))
    }

    private func refreshProcesses() {
        lastProcs = procSampler.sample(window: TimeInterval(procWindow))
        rebuildRows()
    }

    /// Sorts on the numbers alone, then looks up names and icons for the
    /// rows shown only.
    private func rebuildRows() {
        set(\.hiddenProcs, max(0, procSampler.total - lastProcs.count))

        var entries: [(pid: pid_t, cpu: Double, mem: UInt64, count: Int)]
        if groupApps {
            var groups: [pid_t: (cpu: Double, mem: UInt64, count: Int)] = [:]
            groups.reserveCapacity(lastProcs.count / 2)
            for p in lastProcs {
                groups[p.responsible, default: (0, 0, 0)].cpu += p.cpu
                groups[p.responsible]!.mem += p.mem
                groups[p.responsible]!.count += 1
            }
            entries = groups.map { ($0.key, $0.value.cpu, $0.value.mem, $0.value.count) }
        } else {
            entries = lastProcs.map { ($0.pid, $0.cpu, $0.mem, 1) }
        }
        if sortByMemory {
            entries.sort { $0.mem > $1.mem }
        } else {
            entries.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.mem > $1.mem }
        }
        let top = entries.prefix(Self.rowCount).map { e -> ProcRow in
            let app = groupApps ? appInfo(e.pid) : nil
            return ProcRow(id: e.pid, name: app?.name ?? procSampler.name(of: e.pid),
                           cpu: e.cpu, mem: e.mem, count: e.count, isApp: app != nil, icon: app?.icon)
        }
        if top != rows { rows = top }
        if appCache.count > Self.rowCount * 3 {
            let shown = Set(top.map(\.id))
            appCache = appCache.filter { shown.contains($0.key) }
        }
    }

    private func appInfo(_ pid: pid_t) -> (name: String, icon: NSImage)? {
        if let cached = appCache[pid], cached.info != nil || Date().timeIntervalSince(cached.at) < 10 {
            return cached.info
        }
        var info: (name: String, icon: NSImage)?
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
            icon.size = NSSize(width: 16, height: 16)
            info = (name, icon)
        }
        appCache[pid] = (info, Date())
        return info
    }

    // MARK: Actions

    /// Opens a web search on what the app or process is.
    func searchWeb(_ row: ProcRow) {
        let query = row.isApp ? "\(row.name) Mac app" : "\(row.name) macOS process"
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        if let u = url.url { NSWorkspace.shared.open(u) }
    }

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

    private var syncingLaunchAtLogin = false

    private func launchAtLoginSilently(_ on: Bool) {
        syncingLaunchAtLogin = true
        launchAtLogin = on
        syncingLaunchAtLogin = false
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard !syncingLaunchAtLogin else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            flash("Démarrage auto : \(error.localizedDescription)")
        }
        // A failed or pending registration leaves the switch on the state
        // macOS actually has.
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin {
            DispatchQueue.main.async { [weak self] in self?.launchAtLoginSilently(enabled) }
        }
    }
}
