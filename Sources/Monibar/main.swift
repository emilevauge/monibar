import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemSampler()
    private var model: PanelModel!
    private var status: StatusController!
    private var timer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = PanelModel(sampler: sampler)
        status = StatusController(model: model)
        model.onIconWindowChange = { [weak self] in self?.updateIcon() }
        // MB_OFFLINE (debug) keeps the no-Internet alert shown, to check the icon.
        let forceOffline = ProcessInfo.processInfo.environment["MB_OFFLINE"] != nil
        model.onOfflineChange = { [weak self] in self?.status.setOffline($0 || forceOffline) }
        if forceOffline { status.setOffline(true) }
        model.drift.onActiveChange = { [weak self] in self?.status.setHog($0) }

        sampler.sampleCPU()
        updateIcon()
        model.minuteTick()

        NotificationHub.shared.start()
        UpdateChecker.startPeriodicCheck()

        // One timer for everything. The leeway lets macOS coalesce wakeups.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + SystemSampler.interval,
                   repeating: SystemSampler.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        let args = CommandLine.arguments
        if args.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.status.show(pinned: true) }
        }
        if args.contains("--snapshot") { snapshot(light: args.contains("--light")) }
        if let n = ProcessInfo.processInfo.environment["MB_CYCLES"].flatMap(Int.init) { cycle(n) }
        if ProcessInfo.processInfo.environment["MB_BENCH"] != nil { bench() }
        // MB_DRIFT (debug): Monibar itself at 95 % of a core for 10 min, to see the alert.
        if ProcessInfo.processInfo.environment["MB_DRIFT"] != nil {
            let me = getpid()
            for _ in 0..<10 { model.drift.feed([DriftWatch.Sample(pid: me, cpu: 95, mem: 0)]) }
            // The status item's window, for `screencapture -l`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let item = NSApp.windows.first(where: { $0.className.contains("StatusBar") }) {
                    print("icon window", item.windowNumber)
                    fflush(stdout)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UNUserNotificationCenter.current().getDeliveredNotifications { list in
                    for n in list where n.request.identifier.hasPrefix("monibar.drift") {
                        print(n.request.content.title, "|", n.request.content.body)
                    }
                    exit(0)
                }
            }
        }
    }

    /// Debug: times each sampling step, then quits.
    private func bench() {
        func time(_ label: String, _ n: Int, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { body() }
            let us = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1000
            print(String(format: "%-34@ %9.1f µs", label as NSString, us))
        }
        let s = SystemSampler()
        let p = ProcessSampler()
        var ts = TimeSeries()
        for i in 0..<1800 { ts.add(Float(i % 7), from: Double(i * 2), to: Double(i * 2 + 2)) }
        time("sampleCPU (every 2 s)", 2000) { s.sampleCPU() }
        time("sampleOthers (1/min closed)", 300) { s.sampleOthers() }
        time("takeSnapshot (1/min)", 50) { p.takeSnapshot() }
        time("process sample (2 s, open)", 50) { _ = p.sample(window: 10) }
        time("buckets 1800 pts -> 120", 2000) { _ = ts.buckets(window: 3600, count: 120, now: 3600) }
        time("diskSpace", 200) { _ = SystemSampler.diskSpace() }
        time("loadAverage", 2000) { _ = SystemSampler.loadAverage() }
        time("process sample, cold (open)", 1) { _ = ProcessSampler().sample(window: 10) }
        time("panel open (setVisible true)", 1) { self.model.setVisible(true) }
        time("model.tick (open)", 30) { self.model.tick() }
        model.setVisible(false)
        print("update requirement:", SelfUpdater.designatedRequirement() ?? "none (unsigned or ad hoc)")
        exit(0)
    }

    /// Debug: opens and closes the panel `n` times off screen, for leak
    /// checks (`leaks` after "cycles done").
    private func cycle(_ n: Int) {
        guard n > 0 else {
            print("cycles done")
            fflush(stdout)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 10, height: 10),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        model.setVisible(true)
        window.contentView = NSHostingView(rootView: PanelView(model: model))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.tick()
            window.orderOut(nil)
            window.contentView = nil
            self.model.setVisible(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.cycle(n - 1) }
        }
    }

    /// Debug: shows the panel in a plain window and prints its window number,
    /// so `screencapture -l` can grab it. Quits after a few seconds.
    private func snapshot(light: Bool) {
        model.setVisible(true)
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let view = NSHostingView(rootView: PanelView(model: self.model))
            window.contentView = view
            window.setContentSize(view.fittingSize)
            // MB_HOLD keeps the window up, off screen, to measure an open panel.
            let hold = Double(ProcessInfo.processInfo.environment["MB_HOLD"] ?? "")
            window.setFrameTopLeftPoint(hold == nil ? NSPoint(x: 40, y: (NSScreen.main?.frame.maxY ?? 900) - 40)
                                                    : NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            print(window.windowNumber)
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + (hold ?? 2)) { exit(0) }
        }
    }

    private var lastMinuteTick = ProcessInfo.processInfo.systemUptime

    private func tick() {
        // Elapsed time rather than a tick count: macOS may defer timers.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMinuteTick >= ProcessSampler.snapshotInterval - 1 {
            lastMinuteTick = now
            model.minuteTick()
        }
        sampler.sampleCPU()
        updateIcon()
        model.tick()
    }

    private func updateIcon() {
        let window = max(1, Int((Double(model.iconWindow) / SystemSampler.interval).rounded()))
        status.updateIcon(value: Double(sampler.recentCPU.mean(last: window)))
    }
}

MainActor.assumeIsolated {
    // Build step: `Monibar --generate-icon out.png` renders the app icon.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--generate-icon"), i + 1 < args.count {
        exit(AppIcon.writePNG(to: args[i + 1]) ? 0 : 1)
    }
    // Debug: `Monibar --icon out.png [symbol]` renders the menu bar icon at 45 % on dark.
    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
        let view = IconView(frame: .zero)
        view.appearance = NSAppearance(named: .darkAqua)
        view.update(value: 0.45)
        view.setSymbol(i + 2 < args.count ? args[i + 2] : nil)
        let scale: CGFloat = 8
        let size = IconView.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
