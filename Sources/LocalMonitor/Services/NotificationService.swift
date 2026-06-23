import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var authorizationRequested = false

    private init() {}

    func prepare() {
        guard AppPreference.notifications else { return }
        guard !authorizationRequested else { return }
        authorizationRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("LocalMonitor: notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    func notify(title: String, body: String) {
        guard AppPreference.notifications else { return }
        prepare()

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
