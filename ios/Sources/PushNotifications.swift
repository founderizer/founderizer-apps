import FleetCore
import Foundation
import UIKit
import UserNotifications

/// Pings (MOBILE-APP.md 9, owner feature push). The hub sends one for each new Needs-you item to every enrolled phone
/// that gave it a push token: the item's number, its title and, when each one fits a button whole, its options, sealed
/// with this phone's own key and opened by `NeedSeal` (UI-API.md 1.76). The
/// notification content extension (`NeedActions`) draws one button for each option, and a press comes here, also when
/// the app is not running: iOS starts the app in the background for it, and only on an unlocked phone, because every
/// answer button asks for that. A tap on the ping itself opens Needs you.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The category of a ping with buttons. The extension's Info.plist names the same one.
    static let needCategory = "need"

    /// The app's one state, once its window exists. A press in the background needs none.
    weak var store: MobileStore? {
        didSet {
            if let store, openNeeds { store.tab = .needs; openNeeds = false }
            if let store, let token = UserDefaults.standard.string(forKey: PushRegistration.tokenKey) {
                store.pushTokenArrived(token)
            }
        }
    }
    /// A tap on a ping started the app before its window existed.
    private(set) var openNeeds = false
    /// B9: the phone's own record of its links to companies, from the member's store (m4); nil on a phone with none.
    var memberLinks: (any MemberLinkRecords)?
    /// B9: the last tap on a member ping, until the member's pages (m6) take its route (`takeMemberRoute`).
    private(set) var memberTap: MemberTap?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // The category has no buttons of its own: each item has its own options, and the extension sets them.
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.needCategory, actions: [],
                                                                 intentIdentifiers: [], options: [])])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: PushRegistration.tokenKey)
        store?.pushTokenArrived(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Nothing to do: the next start asks again, and the app works without pings.
    }

    /// A ping that arrives while the app is in front still shows, so it looks the same everywhere. iOS's completion is
    /// called on the main thread (`onMain`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let present = completionHandler
        Self.onMain({}, then: { present([.banner, .list, .sound]) })
    }

    /// **A press on a ping's button, or a tap on the ping** (fix round 2, item 102). The work runs on the main actor and
    /// iOS's completion is called after it, on the main thread: the `async` form of this method ran its body and its
    /// completion off the main thread, and UIKit's snapshot of the app, which follows the completion, aborted the app
    /// after every press on a button.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        // The ping's own title names the agent that asks.
        let agent = response.notification.request.content.title
        nonisolated(unsafe) let done = completionHandler
        Self.onMain({ await self.received(info, action: action, agent: agent) }, then: done)
    }

    /// **What a press or a tap on a ping does, by its form.** B9: a member's ping is no item of the owner's hub, so
    /// nothing on it is pressed and a tap opens its link's chat (`memberTapped`); every other ping is the owner's.
    func received(_ info: [AnyHashable: Any], action: String, agent: String,
                  seals: () -> [LinkSeal] = { LinkSealKeys().all() }) async {
        if PingForm.of(info) == .member { return memberTapped(info, action: action, seals: seals) }
        await respond(need: (info["need"] as? NSNumber)?.intValue, options: info["options"] as? [String] ?? [],
                      action: action, agent: agent)
    }

    /// The press answers the item, once; the tap opens Needs you.
    func respond(need: Int?, options: [String], action: String, agent: String = "") async {
        if let need, let choice = NeedPress.choice(action) {
            await NeedPress.answer(need: need, choice: choice, options: options, agent: agent)
        } else if action == UNNotificationDefaultActionIdentifier, need != nil {
            showNeeds()
        }
    }

    /// **A tap on a member ping** (B9, b9-phone-members.md 10.10) opens its part with the links' keys and keeps what
    /// opened: the link and the chat, or nothing when no one link's key opened it. Any other action does nothing: a
    /// member ping has no button, and nothing of it reaches `NeedPress` or Needs you.
    func memberTapped(_ info: [AnyHashable: Any], action: String, seals: () -> [LinkSeal] = { LinkSealKeys().all() }) {
        guard action == UNNotificationDefaultActionIdentifier else { return }
        memberTap = MemberTap(ping: MemberPing.open(info, seals: seals()))
    }

    /// **The route of the last tap on a member ping, once** (for m6): the chat of its link by the record of now, or
    /// Chats (`MemberPing.route`). On a cold start the store comes after the tap (`MobileApp`'s `.task`), so the record
    /// is read here and not at the tap; the record gives only an active link, so a link that ended since gives Chats.
    func takeMemberRoute() -> MemberRoute? {
        guard let tap = memberTap else { return nil }
        memberTap = nil
        return MemberPing.route(tap.ping, records: memberLinks)
    }

    /// Runs `work` on the main actor, then `done` there too: what iOS hands a delegate to call when it is finished must
    /// be called on the main thread, whatever thread the delegate was called on.
    nonisolated static func onMain(_ work: @escaping @MainActor () async -> Void, then done: @escaping () -> Void) {
        nonisolated(unsafe) let finish = done
        Task { @MainActor in
            await work()
            finish()
        }
    }

    private func showNeeds() {
        if let store { store.tab = .needs } else { openNeeds = true }
    }
}

/// This phone asks to show notifications and asks Apple for its token. Only an enrolled phone does it: the hub keeps a
/// token for a device, and the owner's own Mac has none (UI-API.md, "Pings to the owner's phone").
enum PushRegistration {
    static let tokenKey = "pushToken"

    /// Which of Apple's two services this build's token belongs to: Xcode's builds are signed for development, and
    /// a TestFlight or App Store build for production.
    #if DEBUG
    static let environment = "development"
    #else
    static let environment = "production"
    #endif

    /// The first time, iOS asks the owner; after that it answers at once. A phone that may not show notifications
    /// asks Apple for no token, so the hub sends it nothing. The badge is the number on the app's icon: the Needs you
    /// tab's count (`MobileStore.showCountOnIcon`), which the hub's pings carry too.
    @MainActor static func ask() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// One press of an answer button: the hub's current generation first, then the answer with the option's index, a new
/// request number and this installation's label, as UI-API.md asks of every owner write. It sends once and never
/// again by itself. The hub takes one answer for each item and refuses a second one with 409, so whatever did not go
/// is said in a short notification, and the owner decides what comes next.
enum NeedPress {
    static let prefix = "choice-"

    /// The option index of an answer button's identifier, or nil for any other action.
    static func choice(_ action: String) -> Int? {
        guard action.hasPrefix(prefix), let index = Int(action.dropFirst(prefix.count)), index >= 0 else { return nil }
        return index
    }

    /// **A press of a ping's button that the phone does not send** (it says "Open Founderizer to answer." instead):
    /// - Run it once of the door's card of a run (the lane "Give on the iPhone"): a ping shows no script, so a press on
    ///   it never signs it (the owner's "Show the script" of 19 November 2026); he answers it on the card, which shows
    ///   the script. A hub of API 1.247 sends such a ping no buttons; this holds for an older ping.
    /// - The first option of a GitHub App's or an Add device card (`OwnerNeed.firstOptionStartsOnTheMac`): only the
    ///   Mac starts its step, and the hub would close the card on a phone's press that started nothing.
    static func refuses(_ item: OwnerNeed, choice: Int) -> Bool {
        (choice == 0 && item.door_host?.isEmpty == false) || MobileStore.startsOnTheMac(item, choice)
    }

    /// `keys`: where this phone's key is read; a check passes a holder of its own, which holds none.
    static func answer(need: Int, choice: Int, options: [String], agent: String = "",
                       keys: DeviceKey = DeviceKey()) async {
        // **A notification names the agent that asked, never the hub's number** (fix round 3, item 47 and COPY).
        let named = agent.trimmingCharacters(in: .whitespaces).isEmpty ? nil : agent
        let hub = MobileStore.savedHub()
        let client = MobileClient()
        let key: String?
        do { key = try keys.pressKey() } catch {
            return await tell(named ?? String(l10n: "Answer not sent"), String(l10n: "This phone could not read its key. Open Founderizer to answer."),
                              need: need)
        }
        let database: String
        var approval: (statement: String, signature: String)?
        do {
            guard let read = try await client.snapshot(at: hub, key: key, database: nil, etag: nil) else {
                throw MobileError.invalidResponse
            }
            database = read.snapshot.db
            let item = read.snapshot.needs.first { $0.id == need }
            if let item, refuses(item, choice: choice) {
                return await tell(named ?? String(l10n: "Answer not sent"), String(l10n: "Open Founderizer to answer."),
                                  need: need)
            }
            // owner feature door_calls: the yes to a door call is signed with this phone's own key, as in the app
            approval = item.flatMap { DeviceSigningKey().approval(for: $0, choice: choice) }
        } catch {
            return await tell(named ?? String(l10n: "Answer not sent"), words(error, need: need), need: need)
        }
        let request = PendingRequest(hub: hub, database: database, client: MobileStore.installationLabel(),
                                     needID: need, choice: choice, approval: approval,
                                     text: options.indices.contains(choice) ? options[choice] : "")
        do {
            _ = try await client.send(request, key: key)
        } catch MobileError.noAnswer {
            // The answer may have arrived. Sending it again could not make a second answer, but it is the owner's
            // call: the app shows whether the item is still open.
            await tell(named ?? String(l10n: "Answer not confirmed"),
                       String(l10n: "Your hub did not answer. Open Founderizer to see whether it is answered."), need: need)
        } catch {
            await tell(named ?? String(l10n: "Answer not sent"), words(error, need: need), need: need)
        }
    }

    /// Why an answer did not go, in the owner's words, with the next step where there is one.
    static func words(_ error: any Error, need: Int) -> String {
        // A failure of the phone itself says only where to go on: its system words are no news to the owner.
        guard let error = error as? MobileError else { return String(l10n: "Open Founderizer to answer.") }
        switch error {
        // What a refusal means is read from its code (`HubRefusal.means`), and for a hub that sends none from the old
        // English phrase: its words are for the owner to read, and in Spanish they are not the hub's. The status is
        // this line's own test.
        case .refusal(let refusal, _) where refusal.status == 409 && refusal.means(.requestAnswered):
            return String(l10n: "Already answered.")
        case .refusal(let refusal, _) where refusal.status == 409 && refusal.means(.hubChanged):
            return String(l10n: "The hub's records changed after the ping. Open Founderizer and answer there.")
        case .refusal(let refusal, _) where refusal.status == 404:
            return String(l10n: "This request is no longer on the hub.")
        case .refusal(_, let auth?):
            return MobileError.authWords(auth)
        case .noAnswer:
            return String(l10n: "Your hub did not answer. Open Founderizer to answer.")
        default:
            return String(l10n: "\(error.localizedDescription) Open Founderizer to answer.")
        }
    }

    /// A short notification of this phone's own. A tap on it opens Needs you, as a tap on the ping does.
    static func tell(_ title: String, _ body: String, need: Int) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "needs"
        content.userInfo = ["need": need]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "answer-\(need)-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
