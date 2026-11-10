import Foundation
import UserNotifications

/// One Mac notification per new ask (1.16, Kika's design): it shows even when
/// the menu bar icon is hidden, never plays a sound, and a click opens the
/// ask. Asked for permission the first time an ask comes, never before.
@MainActor
final class AskNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AskNotifier()

    /// A click on a notification: the server whose ask it was.
    var open: ((String) -> Void)?

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ asks: [AgentAsk]) {
        let items = asks.map { (id: $0.id, server: $0.server, body: AskText.notification($0)) }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = "mcpock"
                content.body = item.body
                content.sound = nil
                content.userInfo = ["server": item.server]
                center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
            }
        }
    }

    /// An ask was answered or ended: its notification goes too.
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let server = response.notification.request.content.userInfo["server"] as? String
        Task { @MainActor in
            if let server { AskNotifier.shared.open?(server) }
        }
        completionHandler()
    }
}
