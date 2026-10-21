import AppKit
import UserNotifications

/// The single `UNUserNotificationCenter` delegate of the app. The center
/// has one delegate and one set of categories, so the update
/// notifications register here instead of each claiming them. A response
/// goes to the handler of the notification's kind, stored in its userInfo.
///
/// Without a bundle id (dev binary from `swift build`) the center crashes
/// on first use: everything here is then a no-op and `isAvailable` is false.
@MainActor
final class NotificationHub: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHub()

    /// userInfo key holding the kind that routes a response.
    nonisolated static let kindKey = "monibar.kind"

    /// Action identifier and string userInfo of a response.
    typealias Handler = @MainActor (_ action: String, _ info: [String: String]) -> Void

    let isAvailable = Bundle.main.bundleIdentifier != nil
    /// Whether macOS lets Monibar show notifications: nil until known, and
    /// always nil without a bundle id. Refreshed by `refreshAuthorization`.
    @Published private(set) var authorization: UNAuthorizationStatus?
    private var categories: [String: UNNotificationCategory] = [:]
    private var handlers: [String: Handler] = [:]
    private var started = false

    private override init() {
        super.init()
    }

    /// Becomes the delegate and asks for permission, once.
    func start() {
        guard isAvailable, !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestAuthorization()
    }

    /// Asks for permission. macOS shows the prompt only while the status
    /// is not determined; afterwards only System Settings changes it.
    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Monibar: notification permission: %@", "\(error)") }
            Task { @MainActor in NotificationHub.shared.refreshAuthorization() }
        }
    }

    /// Reads the current permission, which the user may have changed in
    /// System Settings since the last read.
    func refreshAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in NotificationHub.shared.authorization = status }
        }
    }

    /// The Notifications pane of System Settings.
    static func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// Routes responses to notifications of `kind` to `handler`, and adds
    /// `categories` to the ones the center knows.
    func register(kind: String, categories new: [UNNotificationCategory] = [], handler: @escaping Handler) {
        handlers[kind] = handler
        guard isAvailable else { return }
        for category in new { categories[category.identifier] = category }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    /// Posts `content` tagged with `kind`. No-op without a bundle id.
    func post(kind: String, id: String, content: UNMutableNotificationContent) {
        guard isAvailable else { return }
        content.userInfo[Self.kindKey] = kind
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            // Denied or not registered: no fallback, the user chose so.
            if let error { NSLog("Monibar: notification not posted: %@", "\(error)") }
        }
    }

    func withdraw(id: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    private func route(kind: String, action: String, info: [String: String]) {
        handlers[kind]?(action, info)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shows the banner even while Monibar is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only strings cross to the main actor.
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let action = response.actionIdentifier
        if let kind = info[Self.kindKey] {
            Task { @MainActor in self.route(kind: kind, action: action, info: info) }
        }
        completionHandler()
    }
}
