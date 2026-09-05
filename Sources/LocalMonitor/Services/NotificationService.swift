import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var authorizationRequested = false
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool = { AppPreference.notifications }) {
        self.isEnabled = isEnabled
    }

    func prepare() {
        guard isEnabled() else { return }
        guard !authorizationRequested else { return }
        authorizationRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("LocalMonitor: notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    func notify(title: String, body: String) {
        guard isEnabled() else { return }
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
