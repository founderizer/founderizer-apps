import AppKit
import FleetCore
import Observation
import SwiftUI

/// **The copy of his fleet, kept without him pressing anything.**
///
/// The owner, 20 October 2026, reading that his last copy was 26 hours old: "this should be done automatically
/// via a setting, like a backup and probably on icloud?"
///
/// It does exactly what Save a copy does — take it from the hub, check it against the hub's own digest, write it
/// where he said, and only then confirm it (`FleetCopyModel`) — on the schedule `CopySchedule` decides. Nothing
/// here chooses a moment of its own: `tick` is called from the fleet's own poll, so a copy is taken the first
/// time Founderizer is open after one is due, which is the only promise an app that runs when he runs it can keep.
///
/// **iCloud needs no API.** iCloud Drive is a folder, so a copy written into it is carried off this Mac by Apple
/// and this app asks for no entitlement, no account and no token. It is where a fleet that has never been asked
/// puts its copy, and never forced: an external disk is his to choose instead.
///
/// **It says nothing when it works.** The app announced the first copy with a line over the page, and the owner
/// had it out on 20 October 2026: "I dont like that banner you added to announce the backup, it looks like an
/// error. remove it". The Settings row is the disclosure — it names the folder and the day, and it is there
/// whenever he looks. What still speaks is a copy that is **not** being kept: a folder that vanished and a
/// failure each have their mark on System status, because silence there would mislead him.
@MainActor @Observable
final class FleetCopyKeeper {
    private(set) var schedule: CopySchedule
    /// The name of the folder he chose, for the screens. The folder itself is behind a bookmark.
    private(set) var folderName: String?
    private(set) var busy = false
    /// When the folder was last resolved from its bookmark.
    @ObservationIgnored private var folderReadAt: Date?

    /// How many copies stay in his folder. A week of daily copies is enough to find a fleet that went wrong a few
    /// days ago, and his standing rule is against copies piling up. The screens say this number, because deleting
    /// a file of his quietly is the one thing a backup must never do.
    static let keeps = 7

    private let defaults = UserDefaults.standard

    init(defaults: UserDefaults = .standard) {
        // `object(forKey:)`, not `bool(forKey:)`: nil is "he has never been asked", which is the only state the
        // default applies to. A switch he turned off stays off through every start.
        let decided = defaults.object(forKey: "copyAutomatic") as? Bool
        let every = CopyEvery(rawValue: defaults.string(forKey: "copyEvery") ?? "") ?? .day
        let kept = defaults.object(forKey: "copyKeptAt") as? Double
        let failedAt = defaults.object(forKey: "copyFailedAt") as? Double
        schedule = CopySchedule(on: CopyDefault.on(decided: decided), every: every, hasFolder: false,
                                keptAt: kept.map { Date(timeIntervalSince1970: $0) },
                                failedAt: failedAt.map { Date(timeIntervalSince1970: $0) },
                                failure: defaults.string(forKey: "copyFailure"))
        readFolder()
        if schedule.on, !schedule.hasFolder, defaults.data(forKey: "copyFolder") == nil { takeTheDefaultFolder() }
    }

    /// The place a fleet gets before he chooses one: his iCloud Drive, or his Documents. The folder is made here
    /// and nothing is written into it until a copy is due.
    private func takeTheDefaultFolder() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let wanted = CopyDefault.folder(iCloud: Self.iCloudDrive, documents: documents)
        do {
            try FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true)
            guard let bookmark = try? wanted.bookmarkData() else { return }
            defaults.set(bookmark, forKey: "copyFolder")
            readFolder()
        } catch {
            // Nothing is said here: with no folder the schedule is `noFolder`, which is a cross on System status
            // with Choose a folder behind it, and that is the honest state.
        }
    }

    // ---------------------------------------------------------------- the folder

    /// Where the copies go, resolved from the bookmark each time it is needed. A bookmark and not a path, so a
    /// folder he renames or moves is still the folder he chose. It is not security-scoped: this app is not
    /// sandboxed (`Entitlements.plist`), and a sandbox is the only thing that scope is for.
    var folder: URL? {
        guard let bookmark = defaults.data(forKey: "copyFolder") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: "copyFolder") }
        return url
    }

    /// iCloud Drive, when this Mac has it. It is a folder like any other; the app makes its own folder inside it
    /// and asks for nothing.
    static var iCloudDrive: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        return drive
    }

    var holdsICloud: Bool {
        guard let folder, let drive = Self.iCloudDrive else { return false }
        return folder.path.hasPrefix(drive.path)
    }

    /// His own Mac's panel, and nowhere this app chose for him.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Where Founderizer keeps a copy of your fleet"
        panel.prompt = "Choose"
        panel.message = "Every copy goes here. Founderizer keeps the newest \(Self.keeps) and deletes the older ones."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keep(folder: url)
    }

    /// The suggested place, in one press: a folder of our own inside his iCloud Drive.
    func useICloud() {
        guard let drive = Self.iCloudDrive else { return }
        let ours = drive.appendingPathComponent("Founderizer")
        do {
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            keep(folder: ours)
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func keep(folder: URL) {
        guard let bookmark = try? folder.bookmarkData() else {
            fail("This Mac could not keep that folder. Choose another one.")
            return
        }
        defaults.set(bookmark, forKey: "copyFolder")
        // A folder he just chose makes a failure about the old one meaningless, so it goes with it.
        clearFailure()
        readFolder()
    }

    private func readFolder() {
        let found = folder
        folderName = found.map { Self.words(for: $0) }
        schedule.hasFolder = found != nil
    }

    /// What the folder is called on his screen: iCloud Drive by its own name, anything else by its folder's.
    private static func words(for folder: URL) -> String {
        if let drive = iCloudDrive, folder.path.hasPrefix(drive.path) {
            let rest = folder.path.dropFirst(drive.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › \(rest)"
        }
        return folder.lastPathComponent
    }

    // ---------------------------------------------------------------- what he sets

    func setOn(_ on: Bool) {
        schedule.on = on
        defaults.set(on, forKey: "copyAutomatic")
        if on { clearFailure() }
    }

    func setEvery(_ every: CopyEvery) {
        schedule.every = every
        defaults.set(every.rawValue, forKey: "copyEvery")
    }

    // ---------------------------------------------------------------- keeping one

    /// Called from the fleet's own poll. It does nothing at all until a copy is due, which is two dates compared.
    func tick(store: FleetStore, now: Date = Date()) async {
        guard !busy, schedule.on, store.isFresh, store.state?.db != nil else { return }
        // The folder is read from the disk at most once a minute, not on every poll: this runs every three
        // seconds for the whole life of the app. It has to be read at all, and before the decision, because a
        // folder that was renamed or unplugged is `hasFolder` false — which is a cross on the screen with a
        // button, and not a copy that stops without saying anything.
        if folderReadAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            folderReadAt = now
            readFolder()
        }
        guard schedule.isDue(now: now) else { return }
        await keepOne(store: store, now: now)
    }

    /// Take it, check it, write it where he said, confirm it, then prune. The order is the one the manual copy
    /// takes and for the same reason: a copy he does not hold must never clear the warning.
    private func keepOne(store: FleetStore, now: Date) async {
        guard let database = store.state?.db, let folder else { return }
        busy = true
        defer { busy = false }
        let client = HubClient()
        var taken: FleetCopy?
        defer { taken.map { try? FileManager.default.removeItem(at: $0.file.deletingLastPathComponent()) } }
        do {
            let copy = try await client.takeCopy(hub: store.hub, database: database)
            taken = copy
            let kept = folder.appendingPathComponent(copy.suggestedName)
            try? FileManager.default.removeItem(at: kept)
            // The copy that he keeps carries the fleet's access key, his way back after a lost Mac (`OwnerAccess`).
            try FileManager.default.moveItem(at: OwnerAccess.withKey(copy.file) ?? copy.file, to: kept)
            try await client.confirmCopy(hub: store.hub, database: database, client: store.installation,
                                         sha256: copy.sha256, bytes: copy.bytes)
            prune(in: folder)
            schedule.keptAt = now
            defaults.set(now.timeIntervalSince1970, forKey: "copyKeptAt")
            clearFailure()
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, at: now)
        }
    }

    /// The newest `keeps` stay, the older ones go — and only files of the hub's own naming, only in his folder.
    private func prune(in folder: URL) {
        let manager = FileManager.default
        // Hidden files are listed too: an evicted iCloud copy is `.founderizer-….zip.icloud`, which is still
        // one of his copies and has to be counted as one (`CopyFolder.isACopy(onDisk:)`).
        guard let found = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                           options: []) else { return }
        let dated = found.map { file -> (name: String, at: Date) in
            let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (file.lastPathComponent, at ?? .distantPast)
        }
        for name in CopyFolder.toDelete(dated, keeping: Self.keeps) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func fail(_ says: String, at: Date = Date()) {
        schedule.failure = says
        schedule.failedAt = at
        defaults.set(says, forKey: "copyFailure")
        defaults.set(at.timeIntervalSince1970, forKey: "copyFailedAt")
    }

    private func clearFailure() {
        schedule.failure = nil
        schedule.failedAt = nil
        defaults.removeObject(forKey: "copyFailure")
        defaults.removeObject(forKey: "copyFailedAt")
    }
}
