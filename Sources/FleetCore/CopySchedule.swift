import Foundation

/// How often this Mac keeps a copy of the fleet by itself.
public enum CopyEvery: String, CaseIterable, Sendable, Equatable {
    case day, week

    /// How long one of them lasts. A copy is due when that long has passed since the last one was kept.
    public var seconds: TimeInterval { self == .day ? 24 * 60 * 60 : 7 * 24 * 60 * 60 }
    public var words: String { self == .day ? "Every day" : "Every week" }
}

/// **Keeping the owner's copy without him pressing anything, and saying honestly when that happens.**
///
/// The owner, 20 October 2026, reading that his last copy was 26 hours old: "this should be done automatically
/// via a setting, like a backup and probably on icloud?"
///
/// The hub makes the copy in passing files beside its records, serves it once and keeps nothing of its own, so this
/// Mac is the only thing that can hold one — and this Mac runs only while he runs it. That is the whole difficulty of this type, and it
/// is why **"every day" can never mean a time of day**: nothing wakes this app up. It means *the first time
/// Founderizer is open after a day has passed*, which is what `next(now:)` decides and what `says(now:)` tells
/// him in those words, so no screen ever claims a copy that does not exist.
///
/// It holds no folder and no file, only whether there is one: resolving a bookmark, writing a file and asking the
/// hub all belong to the app, and the decision belongs here, where it is proved without a clock of its own.
public struct CopySchedule: Equatable, Sendable {
    /// He turned it on.
    public var on: Bool
    public var every: CopyEvery
    /// A folder he chose is in place and this Mac can still find it. False is a real state: the folder he chose
    /// can be renamed, unplugged or signed out of, and then nothing is kept until he says where to put it.
    public var hasFolder: Bool
    /// When a copy was last really kept — written to his folder and confirmed with the hub, never before.
    public var keptAt: Date?
    /// When this Mac last tried and could not, and what it said. A failure holds the next attempt back for an
    /// hour: a folder that is gone is gone for a while, and a copy is a whole database over the network, so a
    /// retry every few seconds would ask his hub for one all day.
    public var failedAt: Date?
    public var failure: String?

    public init(on: Bool = false, every: CopyEvery = .day, hasFolder: Bool = false, keptAt: Date? = nil,
                failedAt: Date? = nil, failure: String? = nil) {
        self.on = on
        self.every = every
        self.hasFolder = hasFolder
        self.keptAt = keptAt
        self.failedAt = failedAt
        self.failure = failure
    }

    /// How long a failure holds the next attempt back.
    public static let afterAFailure: TimeInterval = 60 * 60

    /// The warning of the row Keep a copy automatically (Settings › Backup): the failure of the copy that he took
    /// himself with Save copy (`saved`, at `savedAt`) while no copy was kept after it, else the failure of the automatic
    /// copy while the copies are on, else none. A copy of either kind that works after a failed Save copy ends that
    /// warning: an automatic copy by its `keptAt`, and a Save copy that works, which clears its own failure at the
    /// press (the second reader's N9, 22 November 2026).
    public func warning(saved: String?, savedAt: Date?) -> String? {
        if let saved, !(keptAt.flatMap { kept in savedAt.map { kept > $0 } } ?? false) { return saved }
        return on ? failure : nil
    }

    /// What this Mac should do about a copy now.
    public enum Next: Equatable, Sendable {
        /// He has not turned it on.
        case off
        /// It is on and there is no folder to write into. Nothing is kept until he chooses one.
        case noFolder
        /// Take one now.
        case due
        /// Not before this time, either because the last one is still fresh or because the last attempt failed.
        case notUntil(Date)
    }

    public func next(now: Date) -> Next {
        guard on else { return .off }
        guard hasFolder else { return .noFolder }
        if let failedAt {
            let again = failedAt.addingTimeInterval(Self.afterAFailure)
            if now < again { return .notUntil(again) }
        }
        guard let keptAt else { return .due }
        let again = keptAt.addingTimeInterval(every.seconds)
        return now < again ? .notUntil(again) : .due
    }

    public func isDue(now: Date) -> Bool { next(now: now) == .due }

    /// The one line a screen shows, in the owner's own terms, and never a promise this Mac cannot keep.
    public func says(now: Date, folder: String? = nil) -> String {
        switch next(now: now) {
        case .off:
            return "Founderizer takes one by itself and puts it in a folder you choose."
        case .noFolder:
            return "Choose a folder. Nothing is kept until you do."
        case .due:
            return keptAt == nil ? "The first copy is taken as soon as your hub answers."
                : "A copy is due now, and Founderizer takes it as soon as your hub answers."
        case .notUntil(let time):
            let where_ = folder.map { ", in \($0)" } ?? ""
            let kept = keptAt.map { "Last kept \(CopySchedule.day.string(from: $0))\(where_)." }
                ?? "Nothing kept yet."
            if failure != nil {
                return kept + " The last one did not work, and Founderizer tries again after "
                    + CopySchedule.clock.string(from: time) + "."
            }
            // The day and never a time of day: nothing wakes this app up, so an hour here would be a promise
            // that only holds if he happens to be at his Mac.
            return kept + " The next is due \(CopySchedule.onlyTheDay.string(from: time)), and Founderizer takes "
                + "it the first time it is open after that."
        }
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let onlyTheDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// **What a fleet gets before he has said anything.** The owner, 20 October 2026, having found the switch off:
/// "it should be on by default, at least locally, how do we sync it to icloud?"
///
/// So it starts on, with a place to put it already chosen, and a fleet protects itself without him doing
/// anything. The one rule that matters here is the other half: **a decision of his is never overridden**. These
/// take `decided` as an optional on purpose — nil is "he has never been asked", and only that gets the default.
public enum CopyDefault {
    /// Whether to keep copies, for a fleet that has never been asked (nil) and for one that has.
    public static func on(decided: Bool?) -> Bool { decided ?? true }

    /// Where the first copy goes when he has chosen nowhere: his iCloud Drive when this Mac has one, so a copy
    /// leaves the Mac by itself, and his Documents when it has not. Both are ordinary folders — this app is not
    /// sandboxed, so iCloud Drive needs no entitlement, no container and nothing of Apple's beyond the folder.
    public static func folder(iCloud: URL?, documents: URL) -> URL {
        (iCloud ?? documents).appendingPathComponent(name)
    }

    /// The folder this app makes for itself inside whichever of the two it is given.
    public static let name = "Founderizer"

    /// Whether that folder is still to be made: the copies are on, he has chosen no folder, and this start of the app
    /// has not tried yet. It is made when the first copy is due, never when the app starts: macOS guards iCloud Drive
    /// and Documents, and can ask its own question at the first touch.
    public static func waits(on: Bool, chosen: Bool, tried: Bool) -> Bool { on && !chosen && !tried }
}

/// **The time of the last automatic copy and the sizes of the copies, for each hub** (the validator's W1, 23 November
/// 2026). One app meets more than one hub: Start again makes a new one, and a second fleet of the owner's has its own.
/// With one value for the whole app, the second hub's first copy waited a day for the first hub's last one, and its page
/// said the first hub's copies. The key is the hub's address, as the app keeps its other values of a hub
/// (`StartAgain.forgetKept`). A fleet that moved to a new address has no value there until its next copy.
///
/// **The generation of the hub's records (`db`) is kept beside the time**, so the app forgets the values of a hub whose
/// records are another fleet's now: a server that is rebuilt or restored at the same address (a restore moves the
/// generation; `FleetCopyKeeper.tick`). Known limits: an app that never learned a `db` (no copy kept by this build) does
/// not see such a change, and one fleet that the app reaches at two addresses has two entries, so it keeps two copies a
/// day in one folder, and the prune's 7 is then less than 7 days.
public enum CopyKept {
    static let timesKey = "copyKeptAtByHub"
    static let sizesKey = "copySizesByHub"
    static let failuresKey = "copyFailureByHub"
    static let databasesKey = "copyDatabaseByHub"

    /// One address has one key: `http://host:8787` and `http://host:8787/` are the same hub (`HubClient.address` ends in a
    /// slash, the address that a test writes does not).
    public static func key(_ hub: String) -> String { hub.hasSuffix("/") ? String(hub.dropLast()) : hub }

    /// The values of an older build (`copyKeptAt`, `copyFailure`) become those of the hub that the app knows, so that
    /// the update does not take a copy at once and does not lose the words of a failure. Once, at the app's start; an
    /// app with no such value has nothing to move.
    public static func adoptOlder(in defaults: UserDefaults) {
        guard let hub = defaults.string(forKey: "hubAddress") else { return }
        if defaults.object(forKey: timesKey) == nil, let older = defaults.object(forKey: "copyKeptAt") as? Double {
            defaults.set([key(hub): older], forKey: timesKey)
        }
        if defaults.object(forKey: failuresKey) == nil, let words = defaults.string(forKey: "copyFailure"),
           let at = defaults.object(forKey: "copyFailedAt") as? Double {
            defaults.set([key(hub): ["words": words, "at": at] as [String: Any]], forKey: failuresKey)
        }
    }

    public static func keptAt(hub: String, in defaults: UserDefaults) -> Date? {
        (defaults.dictionary(forKey: timesKey)?[key(hub)] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    /// The time of a copy of this hub, and the generation of its records. `copyKeptAt` goes too, for an older build that
    /// reads it.
    public static func keep(at: Date, hub: String, database: String, in defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: timesKey) ?? [:]
        all[key(hub)] = at.timeIntervalSince1970
        defaults.set(all, forKey: timesKey)
        defaults.set(at.timeIntervalSince1970, forKey: "copyKeptAt")
        var known = defaults.dictionary(forKey: databasesKey) ?? [:]
        known[key(hub)] = database
        defaults.set(known, forKey: databasesKey)
    }

    /// The generation that the last copy of this hub had, or nil when this build kept none.
    public static func database(hub: String, in defaults: UserDefaults) -> String? {
        defaults.dictionary(forKey: databasesKey)?[key(hub)] as? String
    }

    /// Everything that this Mac keeps of one hub's copies: the time, the sizes, the failure and the generation.
    public static func forget(hub: String, in defaults: UserDefaults) {
        for table in [timesKey, sizesKey, failuresKey, databasesKey] {
            guard var all = defaults.dictionary(forKey: table), all[key(hub)] != nil else { continue }
            all[key(hub)] = nil
            defaults.set(all, forKey: table)
        }
    }

    // A failure is a hub's own: another hub's page never says it (the validator's and the second reader's points of
    // 23 November 2026).
    public static func failure(hub: String, in defaults: UserDefaults) -> (words: String, at: Date)? {
        guard let all = defaults.dictionary(forKey: failuresKey), let one = all[key(hub)] as? [String: Any],
              let words = one["words"] as? String, let at = one["at"] as? Double else { return nil }
        return (words, Date(timeIntervalSince1970: at))
    }

    public static func keep(failure words: String, at: Date, hub: String, in defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: failuresKey) ?? [:]
        all[key(hub)] = ["words": words, "at": at.timeIntervalSince1970] as [String: Any]
        defaults.set(all, forKey: failuresKey)
    }

    public static func clearFailure(hub: String, in defaults: UserDefaults) {
        guard var all = defaults.dictionary(forKey: failuresKey), all[key(hub)] != nil else { return }
        all[key(hub)] = nil
        defaults.set(all, forKey: failuresKey)
    }

    /// The folder changed, so no failure about the old one holds for any hub.
    public static func clearFailures(in defaults: UserDefaults) { defaults.removeObject(forKey: failuresKey) }

    public static func sizes(hub: String, in defaults: UserDefaults) -> CopyFolder.Kept? {
        guard let all = defaults.dictionary(forKey: sizesKey), let sizes = all[key(hub)] as? [NSNumber], sizes.count == 3
        else { return nil }
        return CopyFolder.Kept(newest: sizes[0].int64Value, count: sizes[1].intValue, total: sizes[2].int64Value)
    }

    public static func keep(sizes: CopyFolder.Kept?, hub: String, in defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: sizesKey) ?? [:]
        all[key(hub)] = sizes.map { [NSNumber(value: $0.newest), NSNumber(value: $0.count), NSNumber(value: $0.total)] }
        defaults.set(all, forKey: sizesKey)
    }

    /// The folder changed, so no size of a copy in the old one holds for any hub.
    public static func forgetSizes(in defaults: UserDefaults) {
        defaults.removeObject(forKey: sizesKey)
    }
}

/// **Which copies go when a new one is kept.** It is the one thing in this feature that deletes a file of his, so
/// it is a decision over names and dates and nothing else, proved on its own.
///
/// Three rules, and all are about not touching what is not ours: only the hub's own naming
/// (`founderizer-<fleet>-<time>.zip`) is ever considered, only the copies of the fleet whose copy was just kept
/// (or, when the kept copy has the app's fallback name with no fleet, only the fallback names), and only the oldest
/// beyond the number he is told about. A folder of his with anything else in it comes out of this untouched.
public enum CopyFolder {
    public static let prefix = "founderizer-"

    /// Of these file names, the ones to delete — each under the name it really has on the disk. `keeping` is how
    /// many copies of `fleet` stay. A copy of another fleet in the same folder is none of this fleet's days: it is
    /// not counted and never deleted here. On 19 November 2026 a copy of a test hub's fleet landed in his folder,
    /// and as one of the seven it pushed a day of his own fleet out. `fleet` is nil when the kept copy's name gave
    /// none (the app's own fallback name, when a hub sent no name): then the fallback names are the group, so that
    /// those copies have a limit too.
    public static func toDelete(_ files: [(name: String, at: Date)], keeping: Int, fleet: String?) -> [String] {
        guard keeping >= 0, let group = group(fleet) else { return [] }
        let ours = files.filter { group(real($0.name)) }.sorted { $0.at > $1.at }
        return ours.dropFirst(keeping).map(\.name)
    }

    /// Which names `toDelete` and `kept` count for a copy kept with this fleet's name: that fleet's copies, or the app's
    /// own fallback names when the kept copy's name gave no fleet. nil for a name that is no fleet's.
    private static func group(_ fleet: String?) -> ((String) -> Bool)? {
        guard let fleet else { return isAFallback }
        guard isAFleet(fleet) else { return nil }
        return { Self.fleet(of: $0) == fleet }
    }

    /// The app's own name for a copy whose hub sent none (`FleetCopy.name(fromDisposition:)`): the prefix, the time
    /// in UTC and `.zip`, with no fleet.
    public static func isAFallback(_ name: String) -> Bool {
        name.range(of: "^founderizer-[0-9]{8}T[0-9]{6}Z\\.zip$", options: .regularExpression) != nil
    }

    /// The fleet that a copy's name gives, or nil for a name that gives none: sixteen lowercase hex characters
    /// between the prefix and the next dash, as the hub's `fleet_id` is.
    public static func fleet(of name: String) -> String? {
        guard isACopy(name) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let fleet = String(rest[..<dash])
        return isAFleet(fleet) ? fleet : nil
    }

    static func isAFleet(_ fleet: String) -> Bool {
        fleet.count == 16 && fleet.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A copy this app wrote, by the only name the hub gives one.
    public static func isACopy(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(".zip") && !name.contains("/")
    }

    /// The same, for a name as the disk has it — **including a copy that iCloud has taken back**.
    ///
    /// A folder in iCloud Drive is an ordinary folder until the disk gets tight; then macOS can evict a file it
    /// has uploaded and leave a placeholder, which in the form this app can still meet is the same name hidden
    /// and suffixed: `.founderizer-….zip.icloud`. The file is not lost and it is still one of his copies, so it
    /// is counted as one and pruned as one. Counting it as something else would quietly keep more copies than he
    /// was told; treating it as missing would be worse, and taking it for a stranger's file worse still.
    public static func isACopy(onDisk name: String) -> Bool { isACopy(real(name)) }

    /// The name a placeholder stands for, or the name itself.
    public static func real(_ name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// The copies that stay in his folder after a prune, weighed.
    public struct Kept: Equatable, Sendable {
        /// The size of the newest copy.
        public let newest: Int64
        public let count: Int
        /// The size of all of them together: what they take of his disk, or of his iCloud.
        public let total: Int64

        public init(newest: Int64, count: Int, total: Int64) {
            self.newest = newest; self.count = count; self.total = total
        }
    }

    /// **The copies that stay after a prune, weighed**, from the same list and the same group that `toDelete` reads, with
    /// each file's size: the newest `keeping` copies of `fleet`, a placeholder of iCloud counted as the copy it stands
    /// for. A copy of another fleet in the folder is none of them. nil when no copy stays.
    public static func kept(_ files: [(name: String, at: Date, bytes: Int64)], keeping: Int, fleet: String?) -> Kept? {
        guard let group = group(fleet) else { return nil }
        let ours = files.filter { group(real($0.name)) }.sorted { $0.at > $1.at }.prefix(max(keeping, 0))
        guard let newest = ours.first else { return nil }
        return Kept(newest: newest.bytes, count: ours.count, total: ours.reduce(0) { $0 + $1.bytes })
    }

    /// **The Where row of Settings › Backup: the folder, and the size of the copies in it** (the owner, 22 November 2026:
    /// "just show the size so they can see it too", and his choice of this form on his tracker page):
    /// "iCloud Drive › Founderizer · last copy 117.4 MB, 7 copies 822.1 MB", with one copy
    /// "iCloud Drive › Founderizer · 1 copy, 117.4 MB", and the folder alone before the first copy that this Mac kept.
    /// The count is the copies that stay, which the app's own number of kept copies bounds (`FleetCopyKeeper.keeps`).
    /// nil with no folder.
    public static func whereWords(folder: String?, kept: Kept?) -> String? {
        guard let folder else { return nil }
        guard let kept, kept.count > 0 else { return folder }
        let sizes = kept.count == 1
            ? String(l10n: "1 copy, \(FleetHealth.storageWords(kept.total))")
            : String(l10n: "last copy \(FleetHealth.storageWords(kept.newest)), \(kept.count) copies \(FleetHealth.storageWords(kept.total))")
        return folder + " · " + sizes
    }
}
