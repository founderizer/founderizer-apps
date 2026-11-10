import Foundation

/// **One catalog entry for one App key on its way to the door**, however many rounds its move takes.
///
/// `DoorKeys.put` registers the secret's reference with the hub before the steps that can fail: the central vault's
/// intake and the owner's grant to the door. A round of the door's sync that failed after the hub step tried again at
/// its next round with a new reference, so each failed round left one more catalog entry: on 6 November 2026 the move of
/// the hub's App key left 49 entries named GITHUB_APP_ACME_KEY, one every five minutes. With the reference kept
/// here, the next round tries again under the same entry, and the hub, the central vault and the grant each take the
/// same step a second time as the same step. It stays in this Mac's preferences, so a restart of the app keeps it, and
/// it goes once the door's file names the App.
public enum DoorKeyReference {
    static func key(hub: URL, database: String, app: String) -> String {
        "doorKeyReference|\(hub.absoluteString)|\(database)|\(app)"
    }

    /// A new reference of the central vault, as the owner's app makes one.
    public static func make() -> String { "bws://\(UUID().uuidString.lowercased())" }

    /// The reference for the move of one App's key: the one that an earlier round kept, or a new one, now kept.
    public static func take(hub: URL, database: String, app: String, in defaults: UserDefaults = .standard) -> String {
        let name = key(hub: hub, database: database, app: app)
        if let kept = defaults.string(forKey: name), LoginSecret.isReference(kept) { return kept }
        let made = make()
        defaults.set(made, forKey: name)
        return made
    }

    /// The door's file names the App: its move keeps no reference any more.
    public static func done(hub: URL, database: String, app: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(hub: hub, database: database, app: app))
    }
}
