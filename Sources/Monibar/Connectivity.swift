import Foundation
import Network

/// Whether the Mac reaches the Internet. NWPathMonitor only tells that a
/// route exists, which stays true behind a dead box or a captive portal, so
/// a path that looks up is confirmed by the request macOS itself uses to
/// detect captive portals: once a minute, on each network change, and when
/// the panel opens.
@MainActor
final class Connectivity {
    enum State {
        case unknown, offline, noInternet, online
    }

    private static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let session = URLSession(configuration: .ephemeral)

    private(set) var state = State.unknown {
        didSet { if state != oldValue { onChange?(state) } }
    }
    var onChange: ((State) -> Void)?

    /// 1 online, 0.5 no Internet access, 0 offline; each point covers the
    /// time since the previous check.
    private(set) var history = TimeSeries()
    private var lastRecord: (wall: Double, uptime: Double)?

    private var monitor: NWPathMonitor?
    private var pathUp = false
    private var probing = false

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(up: path.status == .satisfied) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    private func pathChanged(up: Bool) {
        pathUp = up
        if up { probe() } else { set(.offline) }
    }

    private func set(_ new: State) {
        state = new
        let value: Float = switch new {
        case .online: 1
        case .noInternet: 0.5
        case .offline, .unknown: 0
        }
        // Checks more than 2.5 min apart, or across a sleep or a clock change
        // (wall and uptime disagree), are left as a gap.
        let now = (wall: Date().timeIntervalSinceReferenceDate, uptime: ProcessInfo.processInfo.systemUptime)
        if let last = lastRecord {
            let dt = now.uptime - last.uptime
            if dt > 0, dt <= 150, abs((now.wall - last.wall) - dt) < 2 {
                history.add(value, from: last.wall, to: now.wall)
            }
        }
        lastRecord = now
    }

    /// Called once a minute and when the panel opens.
    func probe() {
        guard pathUp else { return set(.offline) }
        guard !probing else { return }
        probing = true
        let request = URLRequest(url: Self.probeURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 5)
        Task {
            var reached = false
            if let (data, response) = try? await Self.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                // A captive portal answers too, with its own login page.
                reached = String(decoding: data, as: UTF8.self).contains("Success")
            }
            probing = false
            if pathUp { set(reached ? .online : .noInternet) }
        }
    }
}
