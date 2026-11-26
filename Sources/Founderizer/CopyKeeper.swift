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
    /// The copies of the hub that the app shows that stayed in his folder after its last copy that this Mac kept, weighed
    /// (the Where row's sizes), or nil before the first one of that hub and after a change of folder.
    private(set) var kept: CopyFolder.Kept?
    /// The hub (its address) whose copy time and sizes the schedule and `kept` are, or nil before the app knows one.
    @ObservationIgnored private var hub: String?
    /// When the folder was last resolved from its bookmark.
    @ObservationIgnored private var folderReadAt: Date?
    /// This start tried to make the default folder (`takeTheDefaultFolder`), with or without a result.
    @ObservationIgnored private var defaultTried = false
    /// The fleet's access key that goes into each copy (`OwnerAccess.withKey`): the keychain's, or a test's own.
    @ObservationIgnored var accessKey: (String) throws -> OwnerAccessKey = OwnerAccessKeychain.kept
    /// Why the access key did not go into the last copy of the hub that the app shows, automatic or Save copy, in the
    /// system's or this app's words (`OwnerAccess.keyed`), until a copy with the key is kept: Report a problem carries it.
    private(set) var keyCause: String?

    /// How many copies stay in his folder. A week of daily copies is enough to find a fleet that went wrong a few
    /// days ago, and his standing rule is against copies piling up. The screens say this number, because deleting
    /// a file of his quietly is the one thing a backup must never do.
    static let keeps = 7

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        // `object(forKey:)`, not `bool(forKey:)`: nil is "he has never been asked", which is the only state the
        // default applies to. A switch he turned off stays off through every start.
        let decided = defaults.object(forKey: "copyAutomatic") as? Bool
        let every = CopyEvery(rawValue: defaults.string(forKey: "copyEvery") ?? "") ?? .day
        schedule = CopySchedule(on: CopyDefault.on(decided: decided), every: every, hasFolder: false)
        CopyKept.adoptOlder(in: defaults)
        if let hub = defaults.string(forKey: "hubAddress") { show(hub: hub) }
        readFolder()
    }

    /// **The default folder is still to be made**: the copies are on, he chose no folder, and this start has not tried.
    ///
    /// **The app touches no folder of his until a fleet has a copy to keep** (the onboarding test of 13 November
    /// 2026). It made the default folder when it started, before its first window. macOS guards iCloud Drive and
    /// Documents: where a folder of that name already stood that another program had made, macOS asked "Founderizer
    /// would like to access files in your Documents folder" at that moment, and the app showed no window until the
    /// answer. So the folder is made at the first copy (`tick`), away from the main thread, and the window stays
    /// live while macOS asks. Until then the screens name the place where the copies will go (`shownFolderName`),
    /// and nothing counts as missing.
    private var defaultPending: Bool {
        CopyDefault.waits(on: schedule.on, chosen: defaults.data(forKey: "copyFolder") != nil, tried: defaultTried)
    }

    /// The place a fleet gets before he chooses one: his iCloud Drive, or his Documents.
    nonisolated private static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return CopyDefault.folder(iCloud: iCloudDrive, documents: documents)
    }

    /// Makes that folder and gives its bookmark, or nil. Nothing is written into it until a copy is due.
    nonisolated private static func makeTheDefaultFolder() -> Data? {
        let wanted = defaultFolder
        do { try FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true) } catch { return nil }
        return try? wanted.bookmarkData()
    }

    /// One try for each start, when the first copy is due. macOS can hold the try behind its own question for as
    /// long as he leaves it open. So the work runs away from the main thread, and **nothing waits for it**: the
    /// fleet's poll calls `tick` and goes on only when `tick` returns, and a poll that waited here would stop every
    /// read of the fleet for as long as the question stood. `busy` holds the next ticks, and the tick after the
    /// answer keeps the first copy.
    private func takeTheDefaultFolder() {
        busy = true
        Task { [weak self] in
            let bookmark = await Task.detached(priority: .utility) { Self.makeTheDefaultFolder() }.value
            guard let self else { return }
            self.defaultTried = true
            // A folder that he chose while macOS asked stays his choice.
            if let bookmark, self.defaults.data(forKey: "copyFolder") == nil {
                self.defaults.set(bookmark, forKey: "copyFolder")
            }
            // With no folder the schedule is `noFolder`, which is a cross on System status with Choose a folder
            // behind it, and that is the honest state.
            self.readFolder()
            self.busy = false
        }
    }

    /// What the Where row says: the folder that holds the copies, or the name of the default one while it is still
    /// to be made. Read by that row only, because it looks for iCloud Drive on the disk.
    var shownFolderName: String? {
        folderName ?? (defaultPending ? Self.words(for: Self.defaultFolder) : nil)
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
    nonisolated static var iCloudDrive: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        return drive
    }

    var holdsICloud: Bool {
        guard let drive = Self.iCloudDrive else { return false }
        // The default folder that is still to be made is the one in iCloud Drive, on a Mac that has it.
        guard let folder else { return defaultPending }
        return folder.path.hasPrefix(drive.path)
    }

    /// His own Mac's panel, and nowhere this app chose for him.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Where Founderizer keeps a copy of your fleet")
        panel.prompt = String(l10n: "Choose")
        panel.message = String(l10n: "Every copy goes here. Founderizer keeps the newest \(Self.keeps) and deletes the older ones, but not the last one with the key to your servers.")
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
            fail(String(l10n: "This Mac could not keep that folder. Choose another one."))
            return
        }
        defaults.set(bookmark, forKey: "copyFolder")
        // A folder he just chose makes a failure about the old one meaningless, so it goes with it, and so do the sizes
        // of the copies in the old one: the new folder's are read at its first copy. For every hub.
        CopyKept.clearFailures(in: defaults)
        clearFailure()
        kept = nil
        CopyKept.forgetSizes(in: defaults)
        readFolder()
    }

    private func readFolder() {
        let found = folder
        folderName = found.map { Self.words(for: $0) }
        // A default folder that is still to be made is no missing folder: it is made at the first copy.
        schedule.hasFolder = found != nil || defaultPending
    }

    /// What the folder is called on his screen: iCloud Drive by its own name, anything else by its folder's.
    nonisolated private static func words(for folder: URL) -> String {
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
        if on {             // a switch turned on starts again for every hub: no old failure holds a copy back
            CopyKept.clearFailures(in: defaults)
            clearFailure()
        }
        readFolder()
    }

    func setEvery(_ every: CopyEvery) {
        schedule.every = every
        defaults.set(every.rawValue, forKey: "copyEvery")
    }

    // ---------------------------------------------------------------- keeping one

    /// The last copy time, the sizes and the failure of the hub that the app shows now (`CopyKept`): that hub's own, never
    /// another hub's, so a new fleet's first copy does not wait a day and its page does not say another hub's copies.
    private func show(hub: String) {
        guard CopyKept.key(hub) != CopyKept.key(self.hub ?? "") else { return }
        self.hub = hub
        schedule.keptAt = CopyKept.keptAt(hub: hub, in: defaults)
        kept = CopyKept.sizes(hub: hub, in: defaults)
        let failure = CopyKept.failure(hub: hub, in: defaults)
        schedule.failure = failure?.words
        schedule.failedAt = failure?.at
        schedule.keyMissing = failure?.keyMissing ?? false
        keyCause = failure?.cause
    }

    /// The records of this address are another fleet's now (a server rebuilt or restored there): the app forgets what it
    /// keeps of the fleet before it (`CopyKept`). The first copy of the new one is due at once.
    private func generation(_ database: String, hub: String) {
        guard let known = CopyKept.database(hub: hub, in: defaults), known != database else { return }
        CopyKept.forget(hub: hub, in: defaults)
        guard CopyKept.key(hub) == CopyKept.key(self.hub ?? "") else { return }
        schedule.keptAt = nil
        schedule.failure = nil
        schedule.failedAt = nil
        schedule.keyMissing = false
        keyCause = nil
        kept = nil
    }

    /// Called from the fleet's own poll. It does nothing at all until a copy is due, which is two dates compared.
    func tick(store: FleetStore, now: Date = Date()) async {
        show(hub: store.hub.absoluteString)
        if let database = store.state?.db { generation(database, hub: store.hub.absoluteString) }
        guard !busy, schedule.on, store.isFresh, store.state?.db != nil else { return }
        // The first copy of a fleet that was never given a folder: the default one is made now, and not before. This
        // tick ends here, and the one after the folder is there keeps the copy.
        if defaultPending {
            takeTheDefaultFolder()
            return
        }
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
        // The hub of this copy, read once: another hub that the app meets while the copy arrives is not its hub, also
        // not for the confirm. The same for the folder: he can choose another one while the copy arrives.
        let hub = store.hub
        busy = true
        defer { busy = false }
        let client = HubClient()
        var taken: FleetCopy?
        defer { taken.map { try? FileManager.default.removeItem(at: $0.file.deletingLastPathComponent()) } }
        do {
            let copy = try await client.takeCopy(hub: hub, database: database)
            taken = copy
            // Only a copy in the one form that a hub writes is kept (`OwnerAccess.checkHubForm`), so no hub's own key
            // stays with him; a copy that is not kept removes no copy of his that has its name.
            let file = copy.file
            let form = try await Task.detached(priority: .utility) { try OwnerAccess.checkHubForm(file) }.value
            let kept = folder.appendingPathComponent(copy.suggestedName)
            try? FileManager.default.removeItem(at: kept)
            // The copy that he keeps carries the fleet's access key, his way back after a lost Mac (`OwnerAccess`). A copy
            // whose key did not go in is kept all the same, and the hub hears that it has none (the audit's finding 1).
            let withKey = try OwnerAccess.keyed(form, key: accessKey)
            try FileManager.default.moveItem(at: withKey.file ?? copy.file, to: kept)
            // Retention knows this copy's key by its name from now on, also once iCloud takes its bytes back, and also
            // when the hub does not take the confirm.
            let fleet = CopyFolder.fleet(of: copy.suggestedName)
            CopyKept.keep(copy: copy.suggestedName, keyed: withKey.file != nil, fleet: fleet, in: defaults)
            try await client.confirmCopy(hub: hub, database: database, client: store.installation,
                                         sha256: copy.sha256, bytes: copy.bytes, keyed: withKey.file != nil)
            let found = prune(in: folder, fleet: fleet)
            // When it was kept, not when it began: a Save copy that failed while this copy arrived ends here
            // (`CopySchedule.warning`; the second reader's R2-3).
            let keptAt = Date(), address = hub.absoluteString
            CopyKept.keep(at: keptAt, hub: address, database: database, in: defaults)
            // The folder that he chose while the copy arrived has no size of the copies of the old one (R15-3).
            let sameFolder = self.folder?.standardizedFileURL.path == folder.standardizedFileURL.path
            CopyKept.keep(sizes: sameFolder ? found : nil, hub: address, in: defaults)
            if CopyKept.key(address) == CopyKept.key(self.hub ?? "") {
                schedule.keptAt = keptAt
                self.kept = sameFolder ? found : nil
            }
            // A copy with no key is a failure of the row until a copy with the key is kept: the next is due on the day
            // as always (`keptAt`), because an hourly retry would turn his seven daily copies into seven hourly ones.
            if withKey.file == nil {
                fail(CopySchedule.noKey, at: keptAt, hub: address, keyMissing: true, cause: withKey.cause)
            } else {
                clearFailure(hub: address)
            }
        } catch {
            // Now, not when the copy began: a copy that takes long and fails waits an hour from the failure (R15-6).
            fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, hub: hub.absoluteString)
        }
    }

    /// The newest `keeps` of this fleet's copies stay, its older ones go — and only files of the hub's own naming
    /// with this fleet's id, only in his folder. A copy whose name gives no fleet prunes the app's fallback names. What
    /// stays, weighed, from the same list and the same group (`CopyFolder.kept`): the folder is read for the sizes at
    /// this moment and at no other, as for the prune itself.
    private func prune(in folder: URL, fleet: String?) -> CopyFolder.Kept? {
        let manager = FileManager.default
        // Hidden files are listed too: an evicted iCloud copy is `.founderizer-….zip.icloud`, which is still
        // one of his copies and has to be counted as one (`CopyFolder.real`).
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let found = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                           options: []) else { return nil }
        let dated = found.map { file -> (name: String, at: Date, bytes: Int64) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file.lastPathComponent, values?.contentModificationDate ?? .distantPast,
                    Self.bytes(of: file, size: values?.fileSize))
        }
        // The newest copy known to carry the access key stays (`CopyFolder.toDelete`): known by this Mac's record of the
        // copies that it kept, else by a read, and each copy is read at most once. The record keeps only the names that
        // are still in the folder.
        CopyKept.keepOnly(Set(dated.map { CopyFolder.real($0.name) }), fleet: fleet, in: defaults)
        var read: [String: Bool?] = [:]
        let keyed = CopyFolder.keyed(known: CopyKept.keyed(fleet: fleet, in: defaults)) { name in
            if let known = read[name] { return known }
            let found = Self.carriesKey(folder.appendingPathComponent(name))
            read[name] = found
            return found
        }
        for name in CopyFolder.toDelete(dated.map { (name: $0.name, at: $0.at) }, keeping: Self.keeps, fleet: fleet,
                                        keyed: keyed) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        return CopyFolder.kept(dated, keeping: Self.keeps, fleet: fleet, keyed: keyed)
    }

    /// Whether the copy in this file carries the fleet's access key (`OwnerAccess.key(in:)`), or nil when its bytes are
    /// not on this Mac now: an iCloud placeholder, or a file that iCloud took back. Such a file is never read here, since
    /// a read would bring the whole copy down from iCloud.
    nonisolated static func carriesKey(_ file: URL) -> Bool? {
        guard CopyFolder.real(file.lastPathComponent) == file.lastPathComponent else { return nil }
        let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus.map({ [.current, .downloaded].contains($0) }) != true { return nil }
        return OwnerAccess.carries(file)
    }

    /// The size of one copy: the file's own, and for a placeholder of iCloud (`.founderizer-….zip.icloud`) the size that
    /// it records of the copy that iCloud holds.
    nonisolated private static func bytes(of file: URL, size: Int?) -> Int64 {
        if CopyFolder.real(file.lastPathComponent) != file.lastPathComponent,
           let recorded = NSDictionary(contentsOf: file)?["NSURLFileSizeKey"] as? NSNumber {
            return recorded.int64Value
        }
        return Int64(size ?? 0)
    }

    /// A failure of one hub's copy, or of the folder (which is the app's, so for the hub that it shows). The older
    /// build's two values go too, for an older build that reads them.
    private func fail(_ says: String, at: Date = Date(), hub failing: String? = nil, keyMissing: Bool = false,
                      cause: String? = nil) {
        guard let address = failing ?? hub else {
            schedule.failure = says
            schedule.failedAt = at
            schedule.keyMissing = keyMissing
            return
        }
        CopyKept.keep(failure: says, at: at, hub: address, keyMissing: keyMissing, cause: cause, in: defaults)
        if CopyKept.key(address) == CopyKept.key(hub ?? address) {
            schedule.failure = says
            schedule.failedAt = at
            schedule.keyMissing = keyMissing
            if keyMissing { keyCause = cause }
        }
        defaults.set(says, forKey: "copyFailure")
        defaults.set(at.timeIntervalSince1970, forKey: "copyFailedAt")
    }

    /// The failure of one hub ends (a copy of it was kept, or he turned the copies on): its own, never another hub's.
    private func clearFailure(hub cleared: String? = nil) {
        let address = cleared ?? hub
        if let address { CopyKept.clearFailure(hub: address, in: defaults) }
        if let address, CopyKept.key(address) != CopyKept.key(hub ?? address) { return }
        schedule.failure = nil
        schedule.failedAt = nil
        schedule.keyMissing = false
        keyCause = nil
        defaults.removeObject(forKey: "copyFailure")
        defaults.removeObject(forKey: "copyFailedAt")
    }

    /// **A Save copy of this hub was kept** (the validator's S2 of 25 November 2026): retention knows its key by its name
    /// (a copy saved into the copies' folder under the hub's name is one of them), and one with the key ends the
    /// automatic copy's "no key" failure at once, since the newest copy then carries the key; one with no key keeps its
    /// cause for Report a problem.
    func saved(_ name: String, keyed: Bool, cause: String?, hub address: String) {
        CopyKept.keep(copy: name, keyed: keyed, fleet: CopyFolder.fleet(of: name), in: defaults)
        guard CopyKept.key(address) == CopyKept.key(hub ?? address) else { return }
        if !keyed {
            keyCause = cause
        } else {
            keyCause = nil
            if schedule.keyMissing { clearFailure(hub: address) }
        }
    }
}
