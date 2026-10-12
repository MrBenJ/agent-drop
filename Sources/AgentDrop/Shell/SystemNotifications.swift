import AgentDropApp
import Foundation
import UserNotifications

/// Spec §6 "Notify on new drops" through UserNotifications. Clicking a notification opens
/// its drop. Unbundled runs (`swift run AgentDrop`) can't use the notification center, so
/// they post nothing.
@MainActor
final class SystemNotifications: NSObject, NoticePosting, UNUserNotificationCenterDelegate {
    var onOpen: (String?) -> Void = { _ in }
    private var askedForPermission = false

    override init() {
        super.init()
        if AppIdentity.isBundled { UNUserNotificationCenter.current().delegate = self }
    }

    func post(_ notices: [NewDropNotice]) {
        guard AppIdentity.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            if !askedForPermission {
                askedForPermission = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            for notice in notices {
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                if let id = notice.dropID { content.userInfo = ["dropID": id] }
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let dropID = response.notification.request.content.userInfo["dropID"] as? String
        await MainActor.run { onOpen(dropID) }
    }

    /// Show banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
