import Foundation
import UserNotifications

/// Opens a sealed ping (`UI-API.md` version 1.76, feature `sealed_push`). founderizer.com and Apple carry only "Needs
/// you", the item's number and a part that the hub sealed with this phone's own key (`SealKey`). This extension opens
/// that part and shows what the ping says, as a ping said it before the seal: the agent that asks over the item's
/// title and, when the item has options, the category whose content extension (`NeedActions`) draws one button for
/// each. The item that a press answers is the one that the sealed part names. A part that does not open leaves the
/// banner as it came, and a tap opens the app. It has no network and no key to the hub.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(request.content)
        }
        SealedPing.show(in: content, key: SealKey().read())
        contentHandler(content)
    }
}
