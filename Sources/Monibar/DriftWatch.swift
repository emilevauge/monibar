import AppKit
import UserNotifications

/// Notifies when a process hogs the Mac: above 80 % of a core for 10 min in
/// a row, or above 2 GB and half as big again as an hour ago. Fed once a
/// minute, panel open or not; at most one alert per process per hour. The
/// notification has Quit and Force Quit buttons.
@MainActor
final class DriftWatch {
    struct Sample {
        let pid: pid_t
        /// Percent of one core over the last minute.
        let cpu: Double
        let mem: UInt64
    }

    private static let cpuLimit = 80.0
    private static let cpuMinutes = 10
    private static let memLimit: UInt64 = 2 << 30
    private static let memGrowth = 1.5
    private static let kind = "drift"
    private static let categoryID = "drift"
    private static let quitID = "drift.quit"
    private static let forceID = "drift.force"

    /// Minutes in a row above the CPU limit.
    private var hotMinutes: [pid_t: Int] = [:]
    /// Footprint each minute over the last hour, for processes above 1 GB only.
    private var memHistory: [pid_t: [(at: Date, mem: UInt64)]] = [:]
    private var alertedAt: [pid_t: Date] = [:]

    init() {
        let quit = UNNotificationAction(identifier: Self.quitID, title: String(localized: "Quit"), options: [])
        let force = UNNotificationAction(identifier: Self.forceID, title: String(localized: "Force Quit"),
                                         options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [quit, force],
                                              intentIdentifiers: [], options: [])
        NotificationHub.shared.register(kind: Self.kind, categories: [category]) { action, info in
            guard action == Self.quitID || action == Self.forceID,
                  let pid = pid_t(info["pid"] ?? ""), let exe = info["exe"] else { return }
            Self.quit(pid: pid, exe: exe, force: action == Self.forceID)
        }
    }

    // shortcut: keyed by pid, so a pid reused within the hour inherits the
    // history; checking the start time would need root for other users' processes.
    func feed(_ samples: [Sample]) {
        let now = Date()
        alertedAt = alertedAt.filter { now.timeIntervalSince($0.value) < 3600 }
        var hot: [pid_t: Int] = [:]
        var mems: [pid_t: [(at: Date, mem: UInt64)]] = [:]
        for s in samples {
            if s.cpu >= Self.cpuLimit {
                let n = (hotMinutes[s.pid] ?? 0) + 1
                hot[s.pid] = n
                if n >= Self.cpuMinutes {
                    alert(s.pid, title: { String(localized: "\($0) is using a lot of CPU") },
                          body: String(localized: "\(Format.cpu(s.cpu)) of a core, above \(Int(Self.cpuLimit))% for \(n) min."))
                }
            }
            guard s.mem >= 1 << 30 else { continue }
            var history = (memHistory[s.pid] ?? []) + [(now, s.mem)]
            history.removeAll { now.timeIntervalSince($0.at) > 3600 }
            mems[s.pid] = history
            if s.mem >= Self.memLimit, let first = history.first, now.timeIntervalSince(first.at) >= 55 * 60,
               Double(s.mem) >= Double(first.mem) * Self.memGrowth {
                let growth = Int((Double(s.mem) / Double(first.mem) - 1) * 100)
                alert(s.pid, title: { String(localized: "\($0) is using more and more memory") },
                      body: String(localized: "\(Format.bytes(s.mem)), up \(growth)% in 1 h."))
            }
        }
        // Processes gone or calm again drop out.
        hotMinutes = hot
        memHistory = mems
    }

    private func alert(_ pid: pid_t, title: (String) -> String, body: String) {
        guard alertedAt[pid] == nil else { return }
        alertedAt[pid] = Date()
        let exe = ProcessSampler.lookUpName(pid)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? exe
        let content = UNMutableNotificationContent()
        content.title = title(name)
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["pid": String(pid), "exe": exe]
        NotificationHub.shared.post(kind: Self.kind, id: "monibar.drift.\(pid)", content: content)
    }

    /// Quits the process, if it is still the one notified. Other users'
    /// processes ask for an administrator password.
    private static func quit(pid: pid_t, exe: String, force: Bool) {
        guard pid > 0, ProcessSampler.lookUpName(pid) == exe else { return }
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
            return
        }
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 { return }
        guard errno == EPERM else { return }
        NSApp.activate(ignoringOtherApps: true)
        let script = "do shell script \"kill -\(force ? "KILL" : "TERM") \(pid)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("Monibar: admin kill of %d failed: %@", pid, error) }
    }
}
