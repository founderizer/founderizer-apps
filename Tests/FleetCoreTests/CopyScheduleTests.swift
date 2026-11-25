import Foundation
import Testing
@testable import FleetCore

/// Whether a copy of the fleet is due, and what the screen says about it. Every case is decided against a time
/// that is given to it, so none of this reads this Mac's clock and none of it waits for one.
struct CopyScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)

    /// **The warning of the row Keep a copy automatically** (Settings › Backup): a failed Save copy stands there until a
    /// copy is kept after it, also while the automatic copies are off; then the automatic copy's own failure, while
    /// they are on, or nothing. The bug that it catches: a Save copy that failed and still says so after the next
    /// automatic copy worked (the second reader's N9, 22 November 2026).
    @Test func aFailedSaveCopyStandsUntilACopyIsKeptAfterIt() {
        let failed = now.addingTimeInterval(-600)
        var copies = CopySchedule(on: true, hasFolder: true, keptAt: now.addingTimeInterval(-86_400))
        #expect(copies.warning(saved: "No room", savedAt: failed) == "No room")
        #expect(copies.warning(saved: nil, savedAt: nil) == nil)
        copies.on = false
        #expect(copies.warning(saved: "No room", savedAt: failed) == "No room")
        copies.on = true
        copies.keptAt = now
        #expect(copies.warning(saved: "No room", savedAt: failed) == nil)
        copies.failure = "The folder is gone."
        #expect(copies.warning(saved: "No room", savedAt: failed) == "The folder is gone.")
        copies.on = false
        #expect(copies.warning(saved: nil, savedAt: nil) == nil)
    }

    @Test func nothingHappensUntilHeTurnsItOn() {
        let off = CopySchedule(on: false, hasFolder: true)
        #expect(off.next(now: now) == .off)
        #expect(!off.isDue(now: now))
        #expect(off.says(now: now).contains("a folder you choose"))
    }

    /// The folder is the one thing this Mac cannot invent, and it can disappear after he chose it: renamed,
    /// unplugged, signed out of. Then nothing is kept and the screen says which of the two it is.
    @Test func withNoFolderNothingIsKeptAndTheScreenSaysSo() {
        let waiting = CopySchedule(on: true, hasFolder: false)
        #expect(waiting.next(now: now) == .noFolder)
        #expect(!waiting.isDue(now: now))
        #expect(waiting.says(now: now) == "Choose a folder. Nothing is kept until you do.")
    }

    @Test func theFirstCopyIsDueAtOnce() {
        let fresh = CopySchedule(on: true, hasFolder: true)
        #expect(fresh.next(now: now) == .due)
        #expect(fresh.says(now: now).contains("The first copy"))
    }

    @Test func aCopyIsDueAgainOnceItsOwnTimeHasPassed() {
        for every in CopyEvery.allCases {
            let kept = CopySchedule(on: true, every: every, hasFolder: true,
                                    keptAt: now.addingTimeInterval(-every.seconds + 60))
            #expect(kept.next(now: now) == .notUntil(now.addingTimeInterval(60)))
            #expect(!kept.isDue(now: now))

            let older = CopySchedule(on: true, every: every, hasFolder: true,
                                     keptAt: now.addingTimeInterval(-every.seconds))
            #expect(older.isDue(now: now))
        }
    }

    /// "Every day" cannot mean a time of day, because nothing wakes this app up. The line has to say that, or he
    /// is told a copy exists that nobody took.
    @Test func theLineSaysThatItWaitsForTheAppToBeOpen() {
        let kept = CopySchedule(on: true, hasFolder: true, keptAt: now.addingTimeInterval(-3600))
        let says = kept.says(now: now, folder: "iCloud Drive")
        #expect(says.contains("in iCloud Drive."))
        #expect(!says.contains("due 20 Oct 2026 at"))
        #expect(says.contains("first time it is open after that"))
    }

    /// A copy is a whole database over the network. A folder that is gone is gone for a while, so a failure holds
    /// the next attempt back for an hour instead of asking the hub for a copy every few seconds all day.
    @Test func aFailureHoldsTheNextAttemptBackForAnHour() {
        let failed = CopySchedule(on: true, hasFolder: true, keptAt: now.addingTimeInterval(-48 * 3600),
                                  failedAt: now.addingTimeInterval(-60), failure: "That folder is not there.")
        #expect(!failed.isDue(now: now))
        #expect(failed.next(now: now) == .notUntil(now.addingTimeInterval(CopySchedule.afterAFailure - 60)))
        #expect(failed.says(now: now).contains("did not work"))

        let later = CopySchedule(on: true, hasFolder: true, keptAt: now.addingTimeInterval(-48 * 3600),
                                 failedAt: now.addingTimeInterval(-CopySchedule.afterAFailure),
                                 failure: "That folder is not there.")
        #expect(later.isDue(now: now))
    }

    /// A copy that was never kept and a failed attempt together still say "nothing kept yet", never a date.
    @Test func aFleetWithNoCopyYetIsNeverGivenADateForOne() {
        let failed = CopySchedule(on: true, hasFolder: true, failedAt: now.addingTimeInterval(-60),
                                  failure: "Your hub did not answer.")
        #expect(failed.says(now: now).hasPrefix("Nothing kept yet."))
    }
}

/// Which copies go when a new one arrives. This is the one part of keeping a copy that deletes a file of his, so
/// every case of it is decided here, over names and dates, with no folder and no disk.
struct CopyFolderTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private let fleet = "0f1e2d3c4b5a6978"
    private func copies(_ count: Int) -> [(name: String, at: Date)] {
        (0..<count).map { ("founderizer-0f1e2d3c4b5a6978-\($0).zip", now.addingTimeInterval(Double(-$0) * 3600)) }
    }

    @Test func theNewestStayAndTheOldestGo() {
        let found = copies(10)
        let gone = CopyFolder.toDelete(found, keeping: 7, fleet: fleet)
        #expect(gone == ["founderizer-0f1e2d3c4b5a6978-7.zip", "founderizer-0f1e2d3c4b5a6978-8.zip",
                         "founderizer-0f1e2d3c4b5a6978-9.zip"])
    }

    @Test func nothingGoesUntilThereAreMoreThanHeIsTold() {
        for count in 0...7 { #expect(CopyFolder.toDelete(copies(count), keeping: 7, fleet: fleet).isEmpty) }
    }

    /// His folder is his. A copy of this fleet in the hub's own naming is the only thing this ever deletes — not a
    /// document, not another app's archive, not a copy he renamed himself, not a copy of another fleet.
    @Test func nothingThatIsNotOneOfOurCopiesIsEverDeleted() {
        let his: [(name: String, at: Date)] = [
            ("Taxes 2026.zip", now.addingTimeInterval(-99 * 3600)),
            ("founderizer.zip", now.addingTimeInterval(-98 * 3600)),
            ("the one I keep.zip", now.addingTimeInterval(-97 * 3600)),
            ("founderizer-0f1e2d3c4b5a6978-old.txt", now.addingTimeInterval(-96 * 3600)),
            ("founderizer-20261020T120000Z.zip", now.addingTimeInterval(-95 * 3600)),
            ("founderizer-0123456789abcdef-20261020T120000Z.zip", now.addingTimeInterval(-94 * 3600))
        ]
        #expect(CopyFolder.toDelete(his + copies(9), keeping: 7, fleet: fleet)
                == ["founderizer-0f1e2d3c4b5a6978-7.zip", "founderizer-0f1e2d3c4b5a6978-8.zip"])
        #expect(CopyFolder.toDelete(his, keeping: 0, fleet: fleet).isEmpty)
        #expect(CopyFolder.toDelete(his + copies(3), keeping: 0, fleet: "").isEmpty)
        #expect(!CopyFolder.isACopy("Taxes 2026.zip"))
        #expect(CopyFolder.isACopy("founderizer-0f1e2d3c4b5a6978-20261020T120000Z.zip"))
        #expect(CopyFolder.fleet(of: "founderizer-0f1e2d3c4b5a6978-20261020T120000Z.zip") == fleet)
        #expect(CopyFolder.fleet(of: "founderizer-20261020T120000Z.zip") == nil)
        #expect(CopyFolder.fleet(of: "founderizer-0F1E2D3C4B5A6978-20261020T120000Z.zip") == nil)
        #expect(CopyFolder.fleet(of: "founderizer-0f1e2d3c4b5a697-20261020T120000Z.zip") == nil)
    }

    /// A copy whose hub sent no name gets the app's fallback name, which gives no fleet. Those copies still have a
    /// limit (none of them takes a fleet's place, and no fleet's copy goes for them).
    @Test func copiesWithTheFallbackNameHaveALimitToo() {
        let fallback: [(name: String, at: Date)] = (0..<9).map {
            ("founderizer-2026102\($0)T120000Z.zip", now.addingTimeInterval(Double(-$0) * 3600))
        }
        #expect(CopyFolder.toDelete(fallback + copies(9), keeping: 7, fleet: nil)
                == ["founderizer-20261027T120000Z.zip", "founderizer-20261028T120000Z.zip"])
        #expect(CopyFolder.toDelete([(".founderizer-20261020T120000Z.zip.icloud", now)] + copies(9), keeping: 0,
                                    fleet: nil) == [".founderizer-20261020T120000Z.zip.icloud"])
    }

    /// A copy of another fleet in his folder is none of his fleet's days (19 November 2026: a copy of a test hub's
    /// fleet landed there, and as one of the seven it pushed a day of his own fleet out). Seven of his and newer
    /// copies of another fleet: none of his goes, and none of the other fleet's either.
    @Test func aCopyOfAnotherFleetTakesNoPlaceOfHis() {
        let other: [(name: String, at: Date)] = (0..<3).map {
            ("founderizer-0123456789abcdef-\($0).zip", now.addingTimeInterval(Double($0 + 1) * 60))
        }
        #expect(CopyFolder.toDelete(other + copies(7), keeping: 7, fleet: fleet).isEmpty)
        #expect(CopyFolder.toDelete(other + copies(8), keeping: 7, fleet: fleet) == ["founderizer-0f1e2d3c4b5a6978-7.zip"])
    }
}

/// What a fleet gets before he has said anything, and the one thing that must never be overridden: a decision
/// of his.
struct CopyDefaultTests {
    private let documents = URL(fileURLWithPath: "/Users/someone/Documents")
    private let iCloud = URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs")

    @Test func aFleetThatWasNeverAskedKeepsCopies() {
        #expect(CopyDefault.on(decided: nil))
    }

    /// He turned it off. Nothing here turns it back on, now or at the next start.
    @Test func aDecisionOfHisIsNeverOverridden() {
        #expect(!CopyDefault.on(decided: false))
        #expect(CopyDefault.on(decided: true))
    }

    @Test func theFirstCopyGoesToICloudDriveWhenThisMacHasOne() {
        #expect(CopyDefault.folder(iCloud: iCloud, documents: documents).path
                == iCloud.appendingPathComponent("Founderizer").path)
        #expect(CopyDefault.folder(iCloud: nil, documents: documents).path
                == documents.appendingPathComponent("Founderizer").path)
    }

    /// The default folder is made at the first copy of a fleet that keeps copies and was given no folder.
    @Test func theDefaultFolderWaitsForTheFirstCopy() {
        #expect(CopyDefault.waits(on: true, chosen: false, tried: false))
    }

    /// A folder of his, copies that he turned off, and a try that this start already made: none of them makes it.
    @Test func nothingMakesTheDefaultFolderASecondTimeOrAgainstHim() {
        #expect(!CopyDefault.waits(on: true, chosen: true, tried: false))
        #expect(!CopyDefault.waits(on: false, chosen: false, tried: false))
        #expect(!CopyDefault.waits(on: true, chosen: false, tried: true))
        #expect(!CopyDefault.waits(on: false, chosen: true, tried: true))
    }
}

/// The copy's time and sizes are one hub's (`CopyKept`; the validator's W1, 23 November 2026).
struct CopyKeptTests {
    private let one = "http://100.64.0.1:8787", two = "http://100.64.0.2:8787"
    private let mib: Int64 = 1 << 20

    /// The bug that it catches: a second hub's first copy waits a day for the first hub's last one, and its page says the
    /// first hub's copies; or the copy of one hub takes the place of the other's.
    @Test func eachHubHasItsOwnCopyTimeAndSizes() {
        let defaults = TestDefaults("copy-kept")
        let at = Date(timeIntervalSince1970: 1_792_500_000)
        CopyKept.keep(at: at, hub: one, database: "db-one", in: defaults)
        CopyKept.keep(sizes: CopyFolder.Kept(newest: 117 * mib, count: 7, total: 822 * mib), hub: one, in: defaults)
        #expect(CopyKept.keptAt(hub: two, in: defaults) == nil)
        #expect(CopyKept.sizes(hub: two, in: defaults) == nil)
        CopyKept.keep(at: at.addingTimeInterval(60), hub: two, database: "db-two", in: defaults)
        CopyKept.keep(sizes: CopyFolder.Kept(newest: 3 * mib, count: 1, total: 3 * mib), hub: two, in: defaults)
        #expect(CopyKept.keptAt(hub: one, in: defaults) == at)
        #expect(CopyKept.sizes(hub: one, in: defaults) == CopyFolder.Kept(newest: 117 * mib, count: 7, total: 822 * mib))
        #expect(CopyKept.sizes(hub: two, in: defaults) == CopyFolder.Kept(newest: 3 * mib, count: 1, total: 3 * mib))
        // One hub is one key, whichever way its address ends: the app writes it with a slash, a setting may not.
        #expect(CopyKept.keptAt(hub: one + "/", in: defaults) == at)
        #expect(CopyKept.sizes(hub: one + "/", in: defaults)?.count == 7)
        // A folder change takes the sizes of both: no copy of either is in the new one yet.
        CopyKept.forgetSizes(in: defaults)
        #expect(CopyKept.sizes(hub: one, in: defaults) == nil && CopyKept.sizes(hub: two, in: defaults) == nil)
        #expect(CopyKept.keptAt(hub: one, in: defaults) == at)
    }

    /// A failure is one hub's own (the second reader's R15-1): another hub's page does not say it, a copy of one hub
    /// ends only its own, and a folder change ends them all. The generation is one hub's too, and `forget` takes all
    /// four values of one hub and none of another's.
    @Test func aFailureAndAGenerationAreOneHubs() {
        let defaults = TestDefaults("copy-kept-failure")
        let at = Date(timeIntervalSince1970: 1_792_500_000)
        CopyKept.keep(failure: "The hub refused the copy.", at: at, hub: two, in: defaults)
        #expect(CopyKept.failure(hub: one, in: defaults)?.words == nil)
        #expect(CopyKept.failure(hub: two + "/", in: defaults)?.words == "The hub refused the copy.")
        CopyKept.keep(failure: "Another.", at: at, hub: one, in: defaults)
        CopyKept.clearFailure(hub: one, in: defaults)
        #expect(CopyKept.failure(hub: one, in: defaults)?.words == nil && CopyKept.failure(hub: two, in: defaults)?.words != nil)
        CopyKept.clearFailures(in: defaults)
        #expect(CopyKept.failure(hub: two, in: defaults)?.words == nil)
        CopyKept.keep(at: at, hub: one, database: "db-one", in: defaults)
        CopyKept.keep(sizes: CopyFolder.Kept(newest: mib, count: 1, total: mib), hub: one, in: defaults)
        CopyKept.keep(failure: "Later.", at: at, hub: one, in: defaults)
        CopyKept.keep(at: at, hub: two, database: "db-two", in: defaults)
        #expect(CopyKept.database(hub: one, in: defaults) == "db-one")
        CopyKept.forget(hub: one + "/", in: defaults)
        #expect(CopyKept.keptAt(hub: one, in: defaults) == nil && CopyKept.sizes(hub: one, in: defaults) == nil)
        #expect(CopyKept.failure(hub: one, in: defaults)?.words == nil && CopyKept.database(hub: one, in: defaults) == nil)
        #expect(CopyKept.keptAt(hub: two, in: defaults) == at && CopyKept.database(hub: two, in: defaults) == "db-two")
    }

    /// The one value of an older build is the value of the hub that the app knows, so the update takes no copy at once;
    /// another hub has none, and a second start moves nothing.
    @Test func theOlderBuildsValueIsTheKnownHubsOnly() {
        let defaults = TestDefaults("copy-kept-older")
        let at = Date(timeIntervalSince1970: 1_792_400_000)
        defaults.set(one, forKey: "hubAddress")
        defaults.set(at.timeIntervalSince1970, forKey: "copyKeptAt")
        CopyKept.adoptOlder(in: defaults)
        #expect(CopyKept.keptAt(hub: one, in: defaults) == at)
        #expect(CopyKept.keptAt(hub: two, in: defaults) == nil)
        defaults.set(two, forKey: "hubAddress")
        CopyKept.adoptOlder(in: defaults)
        #expect(CopyKept.keptAt(hub: two, in: defaults) == nil)
        // The older build's failure goes to the hub that it knew, once.
        let older = TestDefaults("copy-kept-older-failure")
        older.set(one, forKey: "hubAddress")
        older.set("The folder is gone.", forKey: "copyFailure")
        older.set(at.timeIntervalSince1970, forKey: "copyFailedAt")
        CopyKept.adoptOlder(in: older)
        #expect(CopyKept.failure(hub: one, in: older)?.words == "The folder is gone.")
        #expect(CopyKept.failure(hub: two, in: older)?.words == nil)
    }
}

/// A copy that iCloud has taken back off this Mac is still one of his copies.
struct CopyEvictionTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)

    /// **The Where row says how much the copies weigh** (the owner, 22 November 2026: "just show the size so they can
    /// see it too", in the form that he chose): the newest copy and all that stay, in his Mac's own numbers, one copy
    /// in its own words, and the folder alone before this Mac kept a copy. The count is the copies that stay after the
    /// prune, a placeholder of iCloud among them, never a number in the words. The bug that it catches: a total that
    /// leaves a copy out, a deleted copy that is still counted, or a wrong form for one copy.
    @Test func theWhereRowSaysWhatTheCopiesWeigh() {
        let mib: Int64 = 1 << 20
        let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
        let place = "iCloud Drive › Founderizer"
        var files = (0..<9).map { day -> (name: String, at: Date, bytes: Int64) in
            ("founderizer-0f1e2d3c4b5a6978-2026111\(day)T101500Z.zip", now.addingTimeInterval(Double(day) * 86_400),
             Int64(100 + day) * mib)
        }
        files[1].name = "." + files[1].name + ".icloud"          // a copy that iCloud took back, with its size recorded
        files.append(("his own notes.txt", now.addingTimeInterval(20 * 86_400), 900 * mib))
        let fleet = "0f1e2d3c4b5a6978"
        let kept = CopyFolder.kept(files, keeping: 7, fleet: fleet)
        // A copy of another fleet in the folder is none of his, even when it is the newest: the row says his copies
        // (the validator's R2, 23 November 2026: "last copy 3 MB, 7 copies 707 MB" for seven of 117 MB).
        let other = (name: "founderizer-0123456789abcdef-20261119T101500Z.zip", at: now.addingTimeInterval(40 * 86_400), bytes: 3 * mib)
        #expect(CopyFolder.kept(files + [other], keeping: 7, fleet: fleet) == kept)
        #expect(CopyFolder.kept([other], keeping: 7, fleet: fleet) == nil)
        #expect(CopyFolder.kept(files, keeping: 7, fleet: nil) == nil)
        // the newest seven of the nine: days 8 down to 2, the placeholder of day 1 and day 0 deleted
        #expect(kept == CopyFolder.Kept(newest: 108 * mib, count: 7, total: (102...108).reduce(0) { $0 + Int64($1) * mib }))
        #expect(CopyFolder.whereWords(folder: place, kept: kept)
                == "\(place) · last copy 108\(decimal)0 MB, 7 copies 735\(decimal)0 MB")
        // the placeholder is a copy that stays when it is among the newest
        #expect(CopyFolder.kept(Array(files[0...1]), keeping: 7, fleet: fleet)?.count == 2)
        let one = CopyFolder.kept([files[0]], keeping: 7, fleet: fleet)
        #expect(CopyFolder.whereWords(folder: place, kept: one) == "\(place) · 1 copy, 100\(decimal)0 MB")
        #expect(CopyFolder.whereWords(folder: place, kept: nil) == place)
        #expect(CopyFolder.kept([files[9]], keeping: 7, fleet: fleet) == nil)
        #expect(CopyFolder.whereWords(folder: nil, kept: kept) == nil)
    }

    @Test func aPlaceholderIsCountedAndPrunedAsTheCopyItStandsFor() {
        #expect(CopyFolder.isACopy(onDisk: ".founderizer-0f1e2d3c4b5a6978-20261020T120000Z.zip.icloud"))
        #expect(CopyFolder.real(".founderizer-abc.zip.icloud") == "founderizer-abc.zip")
        #expect(CopyFolder.real("founderizer-abc.zip") == "founderizer-abc.zip")
        #expect(!CopyFolder.isACopy(onDisk: ".Taxes 2026.zip.icloud"))
        #expect(!CopyFolder.isACopy(onDisk: ".DS_Store"))
    }

    /// Eight copies, two of them evicted: one goes, and it goes under the name the disk really has.
    @Test func theOldestGoesUnderTheNameTheDiskHas() {
        var found: [(name: String, at: Date)] = []
        for index in 0..<8 {
            let plain = "founderizer-0f1e2d3c4b5a6978-\(index).zip"
            let name = index >= 6 ? ".\(plain).icloud" : plain
            found.append((name, now.addingTimeInterval(Double(-index) * 3600)))
        }
        #expect(CopyFolder.toDelete(found, keeping: 7, fleet: "0f1e2d3c4b5a6978") == [".founderizer-0f1e2d3c4b5a6978-7.zip.icloud"])
    }
}
