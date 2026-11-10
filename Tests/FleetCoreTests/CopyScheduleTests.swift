import Foundation
import Testing
@testable import FleetCore

/// Whether a copy of the fleet is due, and what the screen says about it. Every case is decided against a time
/// that is given to it, so none of this reads this Mac's clock and none of it waits for one.
struct CopyScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)

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
    private func copies(_ count: Int) -> [(name: String, at: Date)] {
        (0..<count).map { ("founderizer-0f1e2d3c4b5a6978-\($0).zip", now.addingTimeInterval(Double(-$0) * 3600)) }
    }

    @Test func theNewestStayAndTheOldestGo() {
        let found = copies(10)
        let gone = CopyFolder.toDelete(found, keeping: 7)
        #expect(gone == ["founderizer-0f1e2d3c4b5a6978-7.zip", "founderizer-0f1e2d3c4b5a6978-8.zip",
                         "founderizer-0f1e2d3c4b5a6978-9.zip"])
    }

    @Test func nothingGoesUntilThereAreMoreThanHeIsTold() {
        for count in 0...7 { #expect(CopyFolder.toDelete(copies(count), keeping: 7).isEmpty) }
    }

    /// His folder is his. A copy of the hub's own naming is the only thing this ever deletes — not a document,
    /// not another app's archive, not a copy he renamed himself.
    @Test func nothingThatIsNotOneOfOurCopiesIsEverDeleted() {
        let his: [(name: String, at: Date)] = [
            ("Taxes 2026.zip", now.addingTimeInterval(-99 * 3600)),
            ("founderizer.zip", now.addingTimeInterval(-98 * 3600)),
            ("the one I keep.zip", now.addingTimeInterval(-97 * 3600)),
            ("founderizer-0f1e2d3c4b5a6978-old.txt", now.addingTimeInterval(-96 * 3600))
        ]
        #expect(CopyFolder.toDelete(his + copies(9), keeping: 7).allSatisfy { $0.hasPrefix(CopyFolder.prefix) })
        #expect(CopyFolder.toDelete(his, keeping: 0).isEmpty)
        #expect(!CopyFolder.isACopy("Taxes 2026.zip"))
        #expect(CopyFolder.isACopy("founderizer-0f1e2d3c4b5a6978-20261020T120000Z.zip"))
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
}

/// A copy that iCloud has taken back off this Mac is still one of his copies.
struct CopyEvictionTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)

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
        #expect(CopyFolder.toDelete(found, keeping: 7) == [".founderizer-0f1e2d3c4b5a6978-7.zip.icloud"])
    }
}
