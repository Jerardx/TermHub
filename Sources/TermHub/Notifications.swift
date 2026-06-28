import AppKit
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter that is safe to call when the
/// app is run without a bundle (e.g. via `swift run`), where the notification
/// center is unavailable and would otherwise crash.
enum Notifier {
    /// True only when running from a real .app bundle with an identifier.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("TermHub: notification auth error: \(error)") }
        }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
