import AppKit
import SwiftUI

/// Menu bar item, same behavior as Calbar: the pointer resting on the icon
/// opens the popover in peek mode, which closes once the pointer has left
/// it and the icon. A click opens it for good, until a click outside.
@MainActor
final class StatusController: NSResponder {
    private static let hoverDelay: TimeInterval = 0.5

    private let item = NSStatusBar.system.statusItem(withLength: IconView.size.width + 4)
    private let icon = IconView(frame: .zero)
    private let popover = NSPopover()
    private let model: PanelModel
    private var peeking = false
    private var hoverWork: DispatchWorkItem?
    private var isInside = false
    /// Set on click: no peek until the pointer leaves the icon.
    private var suppressed = false
    private var peekWatch: Timer?
    private var outsideSince: Date?
    private var outsideClicks: Any?
    private var lastText: String?
    /// When the popover last closed: a transient popover closes on the
    /// mouse-down of a click on the icon, before the click's action runs.
    private var closedAt = Date.distantPast

    init(model: PanelModel) {
        self.model = model
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        icon.frame.origin = NSPoint(x: 2, y: (button.bounds.height - IconView.size.height) / 2)
        icon.autoresizingMask = [.minYMargin, .maxYMargin]
        button.addSubview(icon)
        button.addTrackingArea(NSTrackingArea(rect: .zero,
                                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Icon

    /// No Internet, offline or not: a red crossed-out Wi-Fi beside the
    /// capsule, the item 12 pt wider while it shows.
    func setOffline(_ on: Bool) {
        guard on != icon.offline else { return }
        icon.setOffline(on)
        item.length = icon.width + 4
        updateAccessibility()
    }

    private func updateAccessibility() {
        item.button?.setAccessibilityLabel("CPU \(lastText ?? "")%" + (icon.offline ? ", pas d'accès Internet" : ""))
    }

    /// CPU averaged over the chosen window.
    func updateIcon(value: Double) {
        let text = "\(Int((value * 100).rounded()))"
        guard text != lastText else { return }
        lastText = text
        icon.update(value: value)
        updateAccessibility()
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        guard !suppressed, !popover.isShown else { return }
        // The icon can come under a still pointer when the menu bar lays
        // out again: only a pointer that moved onto it counts.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        guard idle < 0.3 else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isInside else { return }
            self.show(peek: true)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        suppressed = false
        hoverWork?.cancel()
        hoverWork = nil
    }

    @objc private func clicked() {
        hoverWork?.cancel()
        suppressed = isInside
        if peeking {
            expandPeek()
        } else if popover.isShown {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            // Not the click that just closed it: that one must not reopen it.
            show(peek: false)
        }
    }

    // MARK: Popover

    func show(pinned: Bool) {
        show(peek: !pinned)
    }

    private func show(peek: Bool) {
        guard let button = item.button, !popover.isShown else { return }
        peeking = peek
        model.setVisible(true)
        let host = PopoverHost(rootView: PanelView(model: model))
        host.popover = popover
        popover.contentViewController = host
        host.fitPopover()
        // A transient popover closes when Monibar deactivates; a peek is
        // closed by its own watch and the outside clicks instead.
        popover.behavior = peek ? .applicationDefined : .transient
        if !peek { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if !peek { popover.contentViewController?.view.window?.makeKey() }
        watchOutsideClicks()
        if peek { watchPeek() }
    }

    /// A click on the peek or the icon keeps the popover open.
    private func expandPeek() {
        guard peeking else { return }
        peeking = false
        stopPeekWatch()
        popover.behavior = .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    private func didClose() {
        closedAt = Date()
        stopPeekWatch()
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        outsideClicks = nil
        peeking = false
        model.setVisible(false)
        // Drop the SwiftUI tree: a closed panel keeps no views alive.
        popover.contentViewController = nil
    }

    /// A transient popover closes on a click outside only while Monibar is
    /// the active app; a peek is not, and would stay open.
    private func watchOutsideClicks() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            if let frame = self.item.button?.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self.close()
        }
    }

    /// Polls the pointer: a tracking area on the popover would miss the gap
    /// between it and the icon. Closes after 0.4 s outside both, and turns
    /// the peek into a full open on a click inside.
    private func watchPeek() {
        outsideSince = nil
        peekWatch?.invalidate()
        peekWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPeek() }
        }
    }

    private func stopPeekWatch() {
        peekWatch?.invalidate()
        peekWatch = nil
    }

    private func checkPeek() {
        guard peeking, popover.isShown else { return stopPeekWatch() }
        let window = popover.contentViewController?.view.window
        if NSEvent.pressedMouseButtons != 0, let frame = window?.frame, frame.contains(NSEvent.mouseLocation) {
            return expandPeek()
        }
        let frames = [item.button?.window?.frame, window?.frame].compactMap { $0 }
        if frames.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) }) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.4 { close() }
        } else {
            outsideSince = Date()
        }
    }
}
