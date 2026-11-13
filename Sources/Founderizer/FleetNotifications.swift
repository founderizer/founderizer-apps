import AppKit
import CryptoKit
import FleetCore
import Observation
import UserNotifications

@MainActor @Observable
final class FleetNotifications: NSObject, UNUserNotificationCenterDelegate {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "notifyNeedsYou")
    private(set) var status: String?
    /// The system's own words for why notifications are unavailable: behind the line, never in it.
    private(set) var cause: String?
    private(set) var requestingPermission = false
    private var lastSnapshot = ""
    private var ledger: NotificationLedger
    private let center = UNUserNotificationCenter.current()
    var openRequest: ((String, Int?) -> Void)?
    var showWindow: (() -> Void)?

    override init() {
        ledger = UserDefaults.standard.data(forKey: "notificationLedger").flatMap { try? JSONDecoder().decode(NotificationLedger.self, from: $0) } ?? NotificationLedger()
        super.init()
        center.delegate = self
    }

    func toggle() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        if enabled {
            enabled = false; status = nil
            center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
        } else {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus != .denied else {
                status = String(l10n: "Allow Founderizer notifications in System Settings.")
                return
            }
            do {
                enabled = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                status = enabled ? nil : String(l10n: "Allow Founderizer notifications in System Settings.")
            } catch { status = String(l10n: "Notifications are unavailable."); cause = error.localizedDescription }
        }
        UserDefaults.standard.set(enabled, forKey: "notifyNeedsYou")
    }

    static func context(hub: URL, database: String) -> String {
        SHA256.hash(data: Data("\(hub.absoluteString)\n\(database)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func update(hub: URL, state: HubState) async {
        let context = Self.context(hub: hub, database: state.db)
        let warning = state.manager_warning?.episode
        let signature = context + "|" + (warning ?? "") + "|" + state.needs.map { "\($0.id):\($0.isOpen):\($0.by)" }.joined(separator: ",")
        guard signature != lastSnapshot else { return }
        lastSnapshot = signature
        let new = ledger.observe(context: context, needs: state.needs)
        let newWarning = ledger.observeWarning(context: context, warning: state.manager_warning)
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "notificationLedger") }
        var open = Set(state.needs.filter(\.isOpen).map { "\(context)/\($0.id)" })
        if let warning { open.insert("\(context)/warning/\(warning)") }
        NSApplication.shared.dockTile.badgeLabel = open.isEmpty ? nil : String(open.count)
        let delivered = await center.deliveredNotifications()
        let answered = delivered.map(\.request.identifier).filter { $0.hasPrefix(context + "/") && !open.contains($0) }
        center.removeDeliveredNotifications(withIdentifiers: answered)
        guard enabled else { return }
        for id in new {
            let content = UNMutableNotificationContent()
            // **The agent that asks, and its question** (T-39, fix round 2): its name as the sidebar writes it over the
            // request's own title, as a chat app names who writes. It said "Founderizer needs you" over "The manager
            // needs your answer." for every request.
            if let need = state.needs.first(where: { $0.id == id }) {
                content.title = need.by.agentLabel
                content.body = need.title.isEmpty ? need.why : need.title
            } else {
                content.title = String(l10n: "Founderizer needs you")
                content.body = String(l10n: "The manager needs your answer.")
            }
            content.sound = .default
            content.threadIdentifier = context
            content.userInfo = ["context": context, "need": id]
            do { try await center.add(UNNotificationRequest(identifier: "\(context)/\(id)", content: content, trigger: nil)) }
            catch { status = String(l10n: "A notification could not be delivered. Check Needs you in Founderizer.") }
        }
        if let newWarning {
            let content = UNMutableNotificationContent()
            content.title = String(l10n: "Check the Founderizer manager")
            content.body = String(l10n: "The manager needs your attention.")
            content.sound = .default
            content.threadIdentifier = context
            content.userInfo = ["context": context]
            do { try await center.add(UNNotificationRequest(identifier: "\(context)/warning/\(newWarning)", content: content, trigger: nil)) }
            catch { status = String(l10n: "A notification could not be delivered. Check the manager in Founderizer.") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let context = response.notification.request.content.userInfo["context"] as? String
        let need = response.notification.request.content.userInfo["need"] as? Int
        Task { @MainActor in
            if let context { openRequest?(context, need) }
            showWindow?()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
