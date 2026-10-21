import SwiftUI
import AppKit

/// The one animation for changes that resize the popover. The popover
/// frame is animated by `PopoverHost` on the same curve and duration, so
/// the panel and its content move together.
enum Motion {
    static let duration: TimeInterval = 0.25
    static let resize = Animation.easeInOut(duration: duration)
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
}

/// Hosting view that reports each change of the size its content asks for.
/// The receiver compares sizes, so extra reports are harmless.
private final class ReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: () -> Void = {}

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
    }

    /// SwiftUI updates its content in a layout pass without always
    /// invalidating the intrinsic size first.
    override func layout() {
        super.layout()
        onSizeChange()
    }
}

/// Content of the popover: hosts the SwiftUI view and resizes the popover
/// to the size the view asks for, animated with `Motion`. A hosting
/// controller as content, or as a child, makes SwiftUI resize the popover
/// itself, at once: the frame jumped to the final size while the content
/// was still animating. Here a plain hosting view sits in a container with
/// no constraints, so only this class sizes the popover.
final class PopoverHost<Content: View>: NSViewController {
    private let host: ReportingHostingView<Content>
    weak var popover: NSPopover?
    private var pendingResize = false

    init(rootView: Content) {
        host = ReportingHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        view = NSView()
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        host.onSizeChange = { [weak self] in self?.scheduleResize() }
    }

    /// The size the content asks for, to set before showing.
    var fittingSize: NSSize {
        _ = view
        return host.intrinsicContentSize
    }

    /// Sets the popover to the content's size at once, before it shows.
    func fitPopover() {
        _ = view
        host.layoutSubtreeIfNeeded()
        let size = host.intrinsicContentSize
        guard let popover, size.width > 0, size.height > 0 else { return }
        popover.contentSize = size
    }

    /// Once per pass: SwiftUI may invalidate several times in a row.
    private func scheduleResize() {
        guard !pendingResize else { return }
        pendingResize = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingResize = false
            self?.resize()
        }
    }

    private func resize() {
        guard let popover else { return }
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0, size != popover.contentSize else { return }
        guard popover.isShown else {
            popover.contentSize = size
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration
            context.timingFunction = Motion.timing
            context.allowsImplicitAnimation = true
            popover.contentSize = size
        }
    }
}
