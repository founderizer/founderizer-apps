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
/// The hub builds the copy in memory, serves it once and keeps nothing of its own, so this Mac is the only thing
/// that can hold one — and this Mac runs only while he runs it. That is the whole difficulty of this type, and it
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

/// **Which copies go when a new one is kept.** It is the one thing in this feature that deletes a file of his, so
/// it is a decision over names and dates and nothing else, proved on its own.
///
/// Two rules, and both are about not touching what is not ours: only the hub's own naming
/// (`founderizer-<fleet>-<time>.zip`) is ever considered, and only the oldest beyond the number he is told about.
/// A folder of his with anything else in it comes out of this untouched.
public enum CopyFolder {
    public static let prefix = "founderizer-"

    /// Of these file names, the ones to delete, oldest first — each under the name it really has on the disk.
    /// `kept` is how many copies stay.
    public static func toDelete(_ files: [(name: String, at: Date)], keeping: Int) -> [String] {
        guard keeping >= 0 else { return [] }
        let ours = files.filter { isACopy(onDisk: $0.name) }.sorted { $0.at > $1.at }
        return ours.dropFirst(keeping).map(\.name)
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
}
