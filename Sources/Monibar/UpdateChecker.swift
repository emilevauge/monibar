import AppKit
import UserNotifications

/// Looks for newer Monibar releases on GitHub, adapted from Calbar. Uses
/// the anonymous releases API (60 requests per hour and per IP, far more
/// than needed). Two entry points:
/// - `startPeriodicCheck()`: at launch, every 24 h and on wake, at most
///   once per 24 h. Posts a notification with an "Update" action, once
///   per new version.
/// - `checkManually()`: from the settings, always asks GitHub and returns
///   the result without touching the notification state.
@MainActor
enum UpdateChecker {
    static let repoURL = URL(string: "https://github.com/emilevauge/monibar")!
    static let assetName = "Monibar.dmg"
    private static let latestAPI = URL(string: "https://api.github.com/repos/emilevauge/monibar/releases/latest")!
    private static let latestPage = URL(string: "https://github.com/emilevauge/monibar/releases/latest")!

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheckedAt"
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    private static let kind = "update"
    private static let categoryID = "update"
    private static let updateActionID = "update.now"
    private static let notesActionID = "update.notes"

    /// The newer release found by the last check, offered in the panel.
    private(set) static var available: GitHubRelease?

    private static var timer: Timer?
    private static var wakeObserver: NSObjectProtocol?

    enum ManualResult {
        case upToDate(current: String)
        case newer(GitHubRelease)
        case error(String)
    }

    /// `CFBundleShortVersionString`, "dev" for a binary without bundle.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Arms the checks. Skipped without a bundle id: a dev binary has no
    /// version to compare and cannot update itself.
    static func startPeriodicCheck() {
        guard Bundle.main.bundleIdentifier != nil, timer == nil else { return }
        registerNotification()
        triggerBackgroundCheck()

        // The timer does not tick while the Mac sleeps: the wake observer
        // covers a long sleep. Both go through the same 24 h cooldown.
        let timer = Timer(timeInterval: checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { triggerBackgroundCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { triggerBackgroundCheck() }
        }
    }

    static func checkManually() async -> ManualResult {
        do {
            let release = try await fetchLatest()
            let current = currentVersion
            guard AppVersion.isNewer(release.version, than: current) else { return .upToDate(current: current) }
            available = release
            return .newer(release)
        } catch {
            NSLog("Monibar: update check failed: %@", "\(error)")
            return .error(String(localized: "GitHub unreachable"))
        }
    }

    // MARK: private

    private static func triggerBackgroundCheck() {
        let defaults = UserDefaults.standard
        guard UpdatePolicy.shouldCheck(lastCheck: defaults.object(forKey: lastCheckKey) as? Date,
                                       now: Date(), interval: checkInterval) else { return }
        Task {
            guard let release = try? await fetchLatest() else { return }
            // Only a check that reached GitHub starts the cooldown.
            defaults.set(Date(), forKey: lastCheckKey)
            if AppVersion.isNewer(release.version, than: currentVersion) { available = release }
            guard UpdatePolicy.shouldNotify(latest: release.version, current: currentVersion,
                                            lastNotified: defaults.string(forKey: lastNotifiedKey)) else { return }
            defaults.set(release.version, forKey: lastNotifiedKey)
            notify(release)
        }
    }

    private static func fetchLatest() async throws -> GitHubRelease {
        var request = URLRequest(url: latestAPI, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Monibar/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try GitHubRelease.parse(data, assetName: assetName, fallbackPage: latestPage)
    }

    // MARK: notification

    private static func registerNotification() {
        let update = UNNotificationAction(identifier: updateActionID, title: String(localized: "Update"), options: [.foreground])
        let notes = UNNotificationAction(identifier: notesActionID, title: String(localized: "Release notes"), options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [update, notes],
                                              intentIdentifiers: [], options: [])
        NotificationHub.shared.register(kind: kind, categories: [category]) { action, info in
            let page = info["pageURL"].flatMap(URL.init(string:)) ?? latestPage
            if action == updateActionID, let dmg = info["dmgURL"].flatMap(URL.init(string:)) {
                install(dmgURL: dmg)
            } else {
                // Body click, "Release notes", or "Update" without a DMG.
                NSWorkspace.shared.open(page)
            }
        }
    }

    /// Downloads and installs, then relaunches. Posts a notification when
    /// the update could not start.
    static func install(dmgURL: URL) {
        Task {
            if let error = await SelfUpdater.run(dmgURL: dmgURL) { notifyFailure(error) }
        }
    }

    private static func notify(_ release: GitHubRelease) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Monibar \(release.version) is available")
        content.body = release.dmgURL == nil
            ? String(localized: "Click to open the release page.")
            : String(localized: "Click Update to install it and relaunch Monibar.")
        content.sound = .default
        content.categoryIdentifier = categoryID
        var info = ["pageURL": release.pageURL.absoluteString]
        if let dmg = release.dmgURL { info["dmgURL"] = dmg.absoluteString }
        content.userInfo = info
        NotificationHub.shared.post(kind: kind, id: "monibar.update.\(release.version)", content: content)
    }

    static func notifyFailure(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Monibar could not update")
        content.body = message
        content.sound = .default
        NotificationHub.shared.post(kind: kind, id: "monibar.update.failed", content: content)
    }
}
