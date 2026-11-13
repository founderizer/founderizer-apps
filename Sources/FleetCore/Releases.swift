import Foundation

/// One release this fleet learned about, and what its own update run came to (`GET /ui/releases`, PRODUCT.md 4.3).
public struct ReleaseRow: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let revision: String
    public let version: String
    public let notes: String?
    /// The revision a fleet must already have to take this release. A fleet without it is told so, and not updated.
    public let minimum: String?
    /// We stopped this release. No fleet takes a held release, because the hold is inside the signed manifest.
    public let hold: Bool
    /// `verified`, `held`, `updating`, `done`, `kept`, `rolled_back` or `failed`.
    public let state: String
    /// Where an update run stood: `clone`, `merge`, `selftest`, `verify`, `push`, `follow` and the others of 4.3.
    public let step: String?
    /// The line the hub wrote for the owner to read as it is. It names the pinned revision whenever the fleet stayed.
    public let says: String?
    /// The revision the fleet ran when the update started, and never left unless the update reached its end.
    public let pinned: String?
    /// The revision the fleet reached, when it did.
    public let reached: String?
    public let seen_at: Double
    public let started_at: Double?
    public let finished_at: Double?
    public let automatic: Bool
    public let applied: Bool

    public var isRunning: Bool { state == "updating" }
    /// A run a person must act on: the release was not taken and the reason is not a hold.
    public var needsOwner: Bool { state == "failed" }
    /// This release can be taken now: it is checked, not held, and no run of it has finished.
    public var isOffered: Bool { state == "verified" && !hold }

    /// What this row says on the screen, in the owner's own words.
    public var summary: String {
        if let says, !says.isEmpty { return says }
        switch state {
        case "verified": return String(l10n: "Release \(version) is on the channel.")
        case "held": return String(l10n: "Release \(version) is held by us. No fleet takes it.")
        case "updating": return String(l10n: "This fleet is updating to \(version)…")
        case "done": return String(l10n: "This fleet runs \(version).")
        case "kept": return String(l10n: "\(version) was not taken, and this fleet did not move.")
        case "rolled_back": return String(l10n: "\(version) did not pass its checks, and this fleet did not move.")
        default: return String(l10n: "The update to \(version) did not finish.")
        }
    }

    /// The notes page of this release, when it is one of our own addresses over HTTPS. A manifest comes from the
    /// network, so the app opens no link of another host.
    public func notesLink(channel: String) -> URL? {
        guard let notes, let link = URL(string: notes), link.scheme == "https",
              let host = link.host?.lowercased(), let site = URL(string: channel)?.host?.lowercased(),
              host == site, link.user == nil, link.password == nil else { return nil }
        return link
    }
}

/// What the hub carries of the old subscription (PRODUCT.md 4.2): a record of `GET /ui/releases`.
///
/// **Founderizer has no subscription and no account, and no screen shows this record.** A hub of today still sends
/// it, and two things still read it until our open channel is the only one: the Mac's own update read names its fleet
/// by `fleet` (`AppUpdate.fleetHeader`), and a key that came with the website's link is traded only while the hub
/// holds no token (`ClaimFromLink`). A hub that sends less of it, or none of it, reads as a fleet with no token.
public struct Entitlement: Codable, Equatable, Sendable {
    public static let feature = "entitlement"
    /// The sixteen hex characters that identify this fleet to our channel, and nothing about its owner. nil until the
    /// fleet has one.
    public let fleet: String?
    public let have_token: Bool
    public let plan: String?
    public let until: Double?
    public let machines: Int?
    public let agents: Int?
    public let verified: Bool
    public let stored_at: Double?
    public let expired: Bool?
    /// What the release channel last said to this fleet.
    public let channel_said: String?
    public let channel_at: Double?

    /// The record of a hub that sends none.
    public static let none = Entitlement(fleet: nil)

    public init(fleet: String?, have_token: Bool = false, plan: String? = nil, until: Double? = nil, machines: Int? = nil,
                agents: Int? = nil, verified: Bool = false, stored_at: Double? = nil, expired: Bool? = nil,
                channel_said: String? = nil, channel_at: Double? = nil) {
        self.fleet = fleet; self.have_token = have_token; self.plan = plan; self.until = until
        self.machines = machines; self.agents = agents; self.verified = verified; self.stored_at = stored_at
        self.expired = expired; self.channel_said = channel_said; self.channel_at = channel_at
    }

    /// Each field that a hub leaves out reads as nothing held.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fleet = try values.decodeIfPresent(String.self, forKey: .fleet)
        have_token = try values.decodeIfPresent(Bool.self, forKey: .have_token) ?? false
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        until = try values.decodeIfPresent(Double.self, forKey: .until)
        machines = try values.decodeIfPresent(Int.self, forKey: .machines)
        agents = try values.decodeIfPresent(Int.self, forKey: .agents)
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        stored_at = try values.decodeIfPresent(Double.self, forKey: .stored_at)
        expired = try values.decodeIfPresent(Bool.self, forKey: .expired)
        channel_said = try values.decodeIfPresent(String.self, forKey: .channel_said)
        channel_at = try values.decodeIfPresent(Double.self, forKey: .channel_at)
    }
}

/// `GET /ui/releases` (owner features `releases` and `entitlement`): the whole Updates screen in one read.
public struct ReleaseState: Codable, Equatable, Sendable {
    public static let feature = "releases"
    public let db: String
    public let time: Double
    /// The revision this fleet runs, and the ref its configuration stands on.
    public let revision: String?
    public let branch: String?
    /// Our release channel, and the published repository every hub carries as `upstream`.
    public let channel: String
    public let upstream: String
    public let automatic: Bool
    /// This fleet takes each release as it is published (team.json setting `releases.early`, PRODUCT.md 4.3 "Two
    /// tracks"), and so does the Mac app that drives it. nil from a hub before that field.
    public let early: Bool?
    /// The public key that checks a manifest ships with the hub. Without it every manifest is refused, which is the
    /// right answer: a fleet that cannot check a release takes none.
    public let have_release_key: Bool
    public let idle: Bool
    public let open_tasks: [Int]
    /// A check or an update is going on in the hub now.
    public let running: Bool
    public let last_check: LastCheck
    /// The hub's record of the old subscription, which no screen shows (`Entitlement`).
    public let entitlement: Entitlement
    public let releases: [ReleaseRow]

    public struct LastCheck: Codable, Equatable, Sendable {
        public let at: Double?
        public let says: String?
        public let status: Int?
    }

    /// A hub that sends no `entitlement` reads as a fleet with none; every other field is read as before.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db)
        time = try values.decode(Double.self, forKey: .time)
        revision = try values.decodeIfPresent(String.self, forKey: .revision)
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        channel = try values.decode(String.self, forKey: .channel)
        upstream = try values.decode(String.self, forKey: .upstream)
        automatic = try values.decode(Bool.self, forKey: .automatic)
        early = try values.decodeIfPresent(Bool.self, forKey: .early)
        have_release_key = try values.decode(Bool.self, forKey: .have_release_key)
        idle = try values.decode(Bool.self, forKey: .idle)
        open_tasks = try values.decode([Int].self, forKey: .open_tasks)
        running = try values.decode(Bool.self, forKey: .running)
        last_check = try values.decode(LastCheck.self, forKey: .last_check)
        entitlement = try values.decodeIfPresent(Entitlement.self, forKey: .entitlement) ?? .none
        releases = try values.decode([ReleaseRow].self, forKey: .releases)
    }

    /// **The reading this Mac kept with the fleet's last one** (the second review of 30 October 2026), for the hub generation
    /// the launch's kept reading is of, or nil: the sidebar's Update row draws from it in a launch's first frame, where it
    /// came after the launch's first reads. The launch reads the releases again as before.
    public static func kept(_ data: Data, database: String) -> ReleaseState? {
        guard let state = try? JSONDecoder().decode(ReleaseState.self, from: data),
              (try? state.validate(database: database)) != nil else { return nil }
        return state
    }

    public func validate(database: String) throws {
        guard db == database, time.isFinite, releases.count <= 100,
              Set(releases.map(\.id)).count == releases.count,
              releases.allSatisfy({ $0.revision.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil }),
              open_tasks.count <= 200,
              URL(string: channel)?.scheme != nil else { throw HubError.invalidResponse }
    }

    /// The release the Update button takes, or nil when there is nothing to take.
    public var offered: ReleaseRow? { releases.first { $0.isOffered } }
    /// The run that is going on, or the newest one that ended.
    public var newestRun: ReleaseRow? { releases.first { $0.started_at != nil } }
    /// The release this fleet runs: the newest one a run of it really reached.
    ///
    /// It used to be the release whose revision is the one the fleet stands on now, and a fleet moves past that
    /// revision the moment anything is written to its configuration ref — a machine that joins, a profile the owner
    /// changes. The screen then said "Your fleet has not taken one of our releases yet" about a fleet that had
    /// taken four of them (19 October 2026). What the owner asks is which of our releases he is on, and that is the
    /// newest one applied, whatever his own commits put on top of it.
    public var current: ReleaseRow? { releases.first { $0.applied && $0.reached != nil } }

    /// Where this fleet stands, as the Updates screen says it: one line in the owner's own words, the release the
    /// one button would take, and the short word at the right when there is no button.
    ///
    /// The order is the order a person needs, and the third branch is the point of it. A fleet that carries no
    /// release key, or a channel that has published nothing, is **not** up to date: it cannot be checked at all,
    /// and a screen that answered "up to date" there would be lying. So only a release a run of this fleet really
    /// reached makes it up to date; everything else says what is missing.
    public var stand: Stand {
        if let run = newestRun, run.isRunning {
            return Stand(says: run.summary, value: String(l10n: "Updating"))
        }
        if let run = newestRun, run.needsOwner {
            return Stand(says: run.summary, value: String(l10n: "Did not finish"), take: offered, waiting: !idle, warn: true)
        }
        if !have_release_key {
            return Stand(says: releases.isEmpty
                         ? String(l10n: "We have published no release yet, and this build carries no key to check one with. Your fleet is not behind.")
                         : String(l10n: "This build has no release key."),
                         value: String(l10n: "Nothing to check"))
        }
        // What our channel answered decides, whatever the hub holds of the old subscription: a channel that refuses
        // a fleet is said as it answered, and a channel that answers a fleet is believed.
        if let status = last_check.status, status != 200 {
            return Stand(says: last_check.says ?? String(l10n: "Our channel answered \(status) when your fleet last asked. Your fleet asks again by itself."),
                         value: String(l10n: "Cannot check"), warn: true)
        }
        if releases.isEmpty {
            // A fleet that has not asked yet knows of no release, and that is not "we have published none": it is
            // what the first install of a fleet read and was never what happened.
            guard last_check.at != nil else { return Stand(says: checkedLine, value: String(l10n: "Nothing to check")) }
            return Stand(says: String(l10n: "We have published no release yet. Your fleet is not behind."), value: String(l10n: "Nothing to check"))
        }
        if let held = releases.first, held.hold { return Stand(says: held.summary, value: String(localized: "Held (a release)", defaultValue: "Held", bundle: Localized.bundle, locale: Localized.digits)) }
        if let ready = offered {
            // Plan P0: a release waits only for the tasks whose turn runs now (`open_tasks`), and for a check that
            // runs, which lists no task. A task between turns, parked or waiting for an answer, does not hold it.
            // **What it waits for is the row's value, and no button is drawn meanwhile** (fix round 3, item 1): the white
            // Update was drawn disabled, with its reason on its hover only.
            let waits = open_tasks.count == 1 ? String(l10n: "Waits for a task")
                : open_tasks.isEmpty ? String(l10n: "Waits for a check") : String(l10n: "Waits for \(open_tasks.count) tasks")
            return Stand(says: idle ? runs : open_tasks.isEmpty ? String(l10n: "It waits until no check runs.")
                                                                : String(l10n: "It waits until no task runs."),
                         value: idle ? "" : waits, take: ready, waiting: !idle)
        }
        if let current { return Stand(says: String(l10n: "Your fleet runs the newest release. \(checkedLine)"), value: current.version) }
        return Stand(says: runs, value: String(l10n: "Unknown"))
    }

    /// Which of our releases this fleet runs, in the owner's own words. The revision under it is this app's
    /// business and not his: a screen of ours names a version, never an id.
    private var runs: String {
        guard let current else { return String(l10n: "Your fleet has not taken one of our releases yet.") }
        return String(l10n: "Your fleet runs \(current.version).")
    }

    /// One row of the Updates screen: what it says, what it shows at the right, and whether it offers a press.
    public struct Stand: Equatable, Sendable {
        /// The one line under the title, in the owner's own words.
        public let says: String
        /// The short word at the right, when no button takes its place.
        public let value: String
        /// The release the Update button would take, or nil when this screen offers no button.
        public let take: ReleaseRow?
        /// The button is drawn and cannot go yet, because the fleet has work open. `says` gives the reason.
        public let waiting: Bool
        /// This line is something to act on: it is drawn in orange.
        public let warn: Bool

        public init(says: String, value: String, take: ReleaseRow? = nil, waiting: Bool = false, warn: Bool = false) {
            self.says = says; self.value = value; self.take = take; self.waiting = waiting; self.warn = warn
        }
    }

    /// When the channel was last asked, in a few words.
    public var checkedLine: String {
        guard let at = last_check.at else { return String(l10n: "Your fleet has not asked our channel yet.") }
        return String(l10n: "Asked \(Servers.age(at, now: time)).")
    }
}

/// The answer of the presses of the Updates screen (`POST /ui/releases/check | update | auto`), and of the token
/// that a key of the website's link is traded for (`entitlement`, `ClaimFromLink`).
public struct ReleaseReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let replayed: Bool
    /// `check` and `update`: the run has started. Its outcome is in the row, because a run takes minutes.
    public let started: Bool?
    public let applying: Bool?
    /// `auto`: whether automatic updates are on now.
    public let automatic: Bool?
    /// `entitlement`: the record as the hub now holds it.
    public let fleet: String?
    public let plan: String?
    public let until: Double?
}
