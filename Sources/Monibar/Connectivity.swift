import Foundation
import Network

/// Whether the Mac reaches the Internet. NWPathMonitor only tells that a
/// route exists, which stays true behind a dead box or a captive portal, so
/// a path that looks up is confirmed by the request macOS itself uses to
/// detect captive portals. Runs only while the panel is open.
@MainActor
final class Connectivity {
    enum State {
        case unknown, offline, noInternet, online
    }

    private static let probeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let probeInterval: TimeInterval = 30
    private static let session = URLSession(configuration: .ephemeral)

    private(set) var state = State.unknown {
        didSet { if state != oldValue { onChange?(state) } }
    }
    var onChange: ((State) -> Void)?

    private var monitor: NWPathMonitor?
    private var timer: Timer?
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func pathChanged(up: Bool) {
        pathUp = up
        if up { probe() } else { state = .offline }
    }

    private func probe() {
        guard pathUp, !probing else { return }
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
            if pathUp { state = reached ? .online : .noInternet }
        }
    }
}
