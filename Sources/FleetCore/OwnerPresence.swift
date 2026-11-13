import Foundation

/// **The owner is at the Mac app** (quiet phone, plan section 10): the app is in front, the screen is not locked, and
/// the last key or mouse input is less than `AppUpdatePolicy.away` old, the time after which the app counts him as
/// away for an update. While that holds, the Mac app's reads of `/ui/state` carry `X-Fleet-Present: 1`, and the hub
/// holds a Needs-you ping for his phone: he sees the item in the sidebar already. The hub counts him present for 10
/// seconds after the last such read, so a Mac that sleeps, quits or loses the network soon reads as away, and the ping
/// goes. Nothing on the screen changes, and there is no setting.
public enum OwnerPresence {
    /// The request header, and its one value.
    public static let header = "X-Fleet-Present"
    public static let value = "1"
    /// Input older than this is no presence.
    public static let idle: TimeInterval = AppUpdatePolicy.away

    /// The rule, pure. `secondsSinceInput` is nil when the Mac could not say: then he is not counted present, so the
    /// phone rings as it did before.
    public static func present(appActive: Bool, screenLocked: Bool, secondsSinceInput: TimeInterval?) -> Bool {
        guard appActive, !screenLocked, let seconds = secondsSinceInput, seconds.isFinite, seconds >= 0 else {
            return false
        }
        return seconds < idle
    }
}
