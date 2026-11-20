import UIKit
import UserNotifications
import UserNotificationsUI

/// The answer buttons of one Needs-you ping (MOBILE-APP.md 9, owner feature push). A notification category has fixed
/// buttons and every item has options of its own, so this extension sets them for each ping, one button for each
/// option the ping carries, in the agent's order. The hub sends options only when each one fits a button whole. An
/// option that only the Mac presses gets no button (`no_button`, API 1.245: Full access on a door card), and each other
/// button keeps its own index, which its press sends.
///
/// Every button asks iOS for an unlocked phone (`.authenticationRequired`), so a press on a locked phone asks for
/// Face ID or the passcode before anything is sent. The extension does not answer the press itself: it has no key and
/// no network, so iOS hands the press to the app (`PushNotifications.swift`).
///
/// It draws nothing of its own. The title and the text of the ping show as iOS draws them, under this view, which is
/// one point high.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: view.bounds.width, height: 1)
    }

    func didReceive(_ notification: UNNotification) {
        let info = notification.request.content.userInfo
        let options = info["options"] as? [String] ?? []
        let noButton = Set(info["no_button"] as? [Int] ?? [])
        extensionContext?.notificationActions = options.enumerated().filter { !noButton.contains($0.offset) }
            .map { index, words in
                UNNotificationAction(identifier: "choice-\(index)", title: words, options: [.authenticationRequired])
            }
    }
}
