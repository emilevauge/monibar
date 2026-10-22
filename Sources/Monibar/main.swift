import AppKit
import SwiftUI

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

    private var ticks = 0

    private func tick() {
        ticks += 1
        if Double(ticks) * SystemSampler.interval >= ProcessSampler.snapshotInterval {
            ticks = 0
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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
