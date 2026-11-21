import Foundation
import Testing
@testable import FleetCore

/// **The window that the sidebar's Update opens** (the owner, 15 November 2026: "a small confirmation modal to update,
/// and be able to do it from there ... This applies to the fleet and to the app", and "a macOS dialog ... it should show
/// everytime there is a fleet update or a macOS update!"): what it names, and what its press takes.
struct UpdateAskTests {
    private static func fleet(rows: [String], idle: Bool = true, automatic: Bool = true, tasks: String = "[]") throws -> ReleaseState {
        let body = """
        {"db": "d", "time": 1792267877, "revision": "aac4cb2196e5b72f1a5295f085780acb1c08cbc1", "branch": "config",
         "channel": "https://platform.founderizer.com", "upstream": "https://github.com/founderizer/founderizer.git",
         "automatic": \(automatic), "have_release_key": true, "idle": \(idle), "open_tasks": \(tasks), "running": false,
         "last_check": {"at": 1792267272, "says": null, "status": 200}, "releases": [\(rows.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(ReleaseState.self, from: Data(body.utf8))
    }

    private static func release(_ id: Int, _ version: String, _ state: String) -> String {
        let revision = String(repeating: String(id % 10), count: 40)
        let done = state == "done"
        return """
        {"id": \(id), "revision": "\(revision)", "version": "\(version)", "notes": null, "minimum": null, "hold": false,
         "state": "\(state)", "step": \(done ? "\"follow\"" : "null"), "says": null, "pinned": null,
         "reached": \(done ? "\"\(revision)\"" : "null"), "seen_at": 1792267272,
         "started_at": \(done ? "1792267300" : "null"), "finished_at": \(done ? "1792267400" : "null"),
         "automatic": true, "applied": \(done)}
        """
    }

    private static let running = AppVersion(name: "0.1.258", build: 259)
    private static let build = AppManifest(version: "0.1.259", build: 260,
                                           url: "https://platform.founderizer.com/a.dmg",
                                           sha256: String(repeating: "a", count: 64), size: 1, minimumSystem: nil,
                                           notes: nil, hold: false, signature: "s")
    private static let offered = AppUpdateReading(status: 200, says: "Update available: 0.1.259", manifest: build,
                                                  offered: true)
    private static let current = AppUpdateReading(status: 200, says: "Up to date", current: true)
    private static let waiting = [release(353, "2026.11.495", "verified"), release(352, "2026.11.494", "done")]
    private static let taken = [release(352, "2026.11.494", "done"), release(346, "2026.11.488", "verified")]

    /// Both wait: one window, a line for each with the version it leaves and the one it takes, and Update and Restart.
    @Test func bothUpdatesAreInOneWindow() throws {
        let ask = UpdateAsk.of(fleet: try Self.fleet(rows: Self.waiting), app: Self.offered, running: Self.running,
                               cannotReplace: nil)
        #expect(ask.title == "Update now?")
        #expect(ask.lines == ["Your fleet: 2026.11.494 → 2026.11.495", "Founderizer for Mac: 0.1.258 → 0.1.259"])
        #expect(ask.fleet?.version == "2026.11.495" && ask.app == Self.build)
        #expect(ask.press == "Update and Restart")
    }

    /// Only the fleet's release: Update, because this Mac does not start again.
    @Test func theFleetAloneIsUpdateWithNoRestart() throws {
        let ask = UpdateAsk.of(fleet: try Self.fleet(rows: Self.waiting), app: Self.current, running: Self.running,
                               cannotReplace: nil)
        #expect(ask.lines == ["Your fleet: 2026.11.494 → 2026.11.495"])
        #expect(ask.app == nil && ask.press == "Update")
    }

    /// Only this Mac's build, also when the hub did not answer: Update and Restart.
    @Test func thisMacAloneIsUpdateAndRestart() throws {
        for fleet in [try Self.fleet(rows: Self.taken), nil] {
            let ask = UpdateAsk.of(fleet: fleet, app: Self.offered, running: Self.running, cannotReplace: nil)
            #expect(ask.lines == ["Founderizer for Mac: 0.1.258 → 0.1.259"])
            #expect(ask.fleet == nil && ask.press == "Update and Restart")
        }
    }

    /// **A release under the one the fleet runs is not in it** (the owner's 2026.11.488 under 2026.11.494): with nothing
    /// else to take the window says so, with OK alone, and names what each one runs.
    @Test func nothingToTakeSaysSoWithOKAlone() throws {
        let ask = UpdateAsk.of(fleet: try Self.fleet(rows: Self.taken), app: Self.current, running: Self.running,
                               cannotReplace: nil)
        #expect(ask.title == "Nothing to update now")
        #expect(ask.lines == ["Your fleet: 2026.11.494", "Founderizer for Mac: 0.1.258"])
        #expect(ask.fleet == nil && ask.app == nil && ask.press == nil)
        // A read of our channel that did not reach it says its own line under this Mac's.
        let unreached = AppUpdateReading(status: 0, says: "Our channel did not answer.", unreachable: true)
        let failed = UpdateAsk.of(fleet: try Self.fleet(rows: Self.taken), app: unreached, running: Self.running,
                                  cannotReplace: nil)
        #expect(failed.lines == ["Your fleet: 2026.11.494", "Founderizer for Mac: 0.1.258", "Our channel did not answer."])
    }

    /// A build that this Mac cannot put in place is named with the reason and not taken; the fleet's release still is.
    @Test func aBuildThisMacCannotPutInPlaceIsNamedAndNotTaken() throws {
        let reason = "Founderizer runs from a disk image. Move it to Applications first."
        let alone = UpdateAsk.of(fleet: try Self.fleet(rows: Self.taken), app: Self.offered, running: Self.running,
                                 cannotReplace: reason)
        #expect(alone.title == "Founderizer 0.1.259 is ready" && alone.lines == [reason] && alone.press == nil)
        let both = UpdateAsk.of(fleet: try Self.fleet(rows: Self.waiting), app: Self.offered, running: Self.running,
                                cannotReplace: reason)
        #expect(both.lines == ["Your fleet: 2026.11.494 → 2026.11.495", "Founderizer for Mac: 0.1.258 → 0.1.259", reason])
        #expect(both.app == nil && both.press == "Update")
    }

    /// **A release that waits only for running work while updates are automatic is not his to press**: the hub takes
    /// it at the first moment no turn runs. With automatic updates off it is, and his press waits for that work.
    @Test func aReleaseThatWaitsForWorkIsHisOnlyWithAutomaticUpdatesOff() throws {
        let busy = try Self.fleet(rows: Self.waiting, idle: false, automatic: true, tasks: "[42]")
        #expect(busy.waitsForPress == nil)
        #expect(UpdateAsk.of(fleet: busy, app: Self.current, running: Self.running, cannotReplace: nil).press == nil)
        let off = try Self.fleet(rows: Self.waiting, idle: false, automatic: false, tasks: "[42]")
        #expect(off.waitsForPress?.version == "2026.11.495")
        #expect(UpdateAsk.of(fleet: off, app: Self.current, running: Self.running, cannotReplace: nil).press == "Update")
    }
}
