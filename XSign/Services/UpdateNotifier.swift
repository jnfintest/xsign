import Foundation
import UserNotifications
import XSignCore

/// Local notifications for new builds, with an "Update" action that opens
/// XSign and starts the update straight away.
enum UpdateNotifier {
    static let categoryID = "xsign.update"
    static let updateActionID = "xsign.update.now"

    static func registerCategories() {
        let update = UNNotificationAction(identifier: updateActionID, title: "Update", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [update], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func notify(about updates: [PendingUpdate]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for update in updates {
            let latest = update.release
            let content = UNMutableNotificationContent()
            content.title = "\(update.item.name) \(latest.displayVersion) is ready"
            content.body = latest.title ?? "From \(update.entry.source.name). Tap Update to sign and install it."
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = ["itemID": update.item.id.uuidString]
            let request = UNNotificationRequest(identifier: "update.\(update.item.id.uuidString).\(latest.id)",
                                                content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
