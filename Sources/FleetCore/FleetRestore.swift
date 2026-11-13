import Compression
import Foundation

/// Putting one copy of the fleet back (owner API 1.5, `POST /ui/restore`).
///
/// The hub's half of this has been built and careful since 18 October 2026, and the app's half did not exist: the
/// `RESTORE.md` written into every copy told the owner to open the app and choose Restore, and there was no such
/// thing anywhere in it. So the only way back from a dead hub machine was a shell on the new one. A copy that
/// cannot be put back through any interface its owner has is not a copy of anything.
///
/// Three things in here are the whole of the care this needs. **What is in the copy is read on this Mac before
/// anything is sent** (`FleetManifest`), because once automatic copies accumulate he will have seven of them in
/// one folder and the file name is a date. **A hub that already holds work is not replaced by accident**: the
/// route answers 409 and the app says what is there and asks again (`FleetHolds`). And **the hub goes away**: it
/// writes the records beside its database and restarts itself to take them, so the app watches for the one signal
/// that says it landed, which is a changed `db` (`RestoreWatch`).

// MARK: - what one copy says about itself

/// `fleet.json`, the manifest inside the copy. It is read on this Mac, before the copy is sent, so the owner sees
/// which of his copies he is about to put back.
///
/// Nothing here is trusted as proof: the hub reads every member of the zip again and compares each SHA-256 with
/// this same manifest before it writes anything (`read_bundle`). This is what the owner is shown, and the hub is
/// what decides.
public struct FleetManifest: Decodable, Sendable, Equatable {
    /// The shape of this file. A hub reads exactly format 1 and refuses another number.
    public let format: Int
    public let made_at: Double
    public let fleet_id: String
    public let db_id: String?
    public let revision: String?
    public let agents: [String]
    /// Each agent that holds a vault store, and the machine it is on. The store key itself is on that machine and
    /// in no copy, so this names the machines whose logins die with their disk.
    public let vault: [String: Holder]?
    /// What the hub that made this copy held on its own disk and did not put in: counts and yes/no only.
    public let hub_only: HubOnly?
    /// What the six-hourly check of that hub last said about these records: `ok`, the problems it found, or nil
    /// before its first check. A copy of a corrupt database is worth taking and is not worth trusting.
    public let integrity: String?
    /// Every member except `RESTORE.md` and this manifest, with its weight and its digest.
    public let files: [String: Member]

    public struct Holder: Decodable, Sendable, Equatable {
        public let machine: String?
        public let mode: String?
        public let recipient: String?
    }
    public struct Member: Decodable, Sendable, Equatable {
        public let bytes: Int64
        public let sha256: String
    }
    /// `hub_only`: the four things that live in `~/.fleet` on the hub machine and go with that disk. Counts and
    /// yes/no, never a value, a name or a fingerprint — which is what makes a copy safe to keep beside his own
    /// files, and is why this is the one place the app can say what he must reconnect.
    public struct HubOnly: Decodable, Sendable, Equatable {
        public let google: Google?
        public let github_app: Present?
        public let mcp: Servers?
        public let attachments: Files?
        public struct Present: Decodable, Sendable, Equatable { public let present: Bool }
        public struct Google: Decodable, Sendable, Equatable {
            public let present: Bool
            public let accounts: Int?
            public let client: Bool?
        }
        public struct Servers: Decodable, Sendable, Equatable {
            public let present: Bool
            public let servers: Int?
        }
        public struct Files: Decodable, Sendable, Equatable {
            public let present: Bool
            public let files: Int?
            public let bytes: Int64?
        }
    }

    /// The name of the records inside the copy. A copy that does not carry them is not a copy of a fleet.
    public static let recordsMember = "fleet.sqlite3"
    public static let manifestMember = "fleet.json"
    public static let configMember = "config/"
    /// The central vault's store and its key, both sealed, which only the owner's recovery code opens (the hub's
    /// `CENTRAL_MEMBER`). A copy carries it while the central vault answered with a recovery key when it was made.
    public static let centralMember = "vault/central.json"
    /// The one format this app reads, which is the one the hub writes.
    public static let format1 = 1

    /// What this manifest has to be before the app will show it as a copy of a fleet. It is deliberately a little
    /// stricter than nothing and a long way short of the hub's own reading: this check is how the app avoids
    /// sending 256 MiB of something that was never a copy, not how a restore is made safe.
    public func check() throws {
        guard format == Self.format1 else { throw RestoreError.otherFormat(format) }
        guard made_at.isFinite, made_at > 0, agents.count <= 1000,
              fleet_id.count <= 64, !fleet_id.isEmpty, fleet_id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              files.count <= 10_000, let records = files[Self.recordsMember], records.bytes > 0,
              files.values.allSatisfy({ $0.bytes >= 0 && isDigest($0.sha256) }),
              files.keys.allSatisfy({ $0 == Self.recordsMember || $0 == Self.centralMember || $0.hasPrefix(Self.configMember) })
        else { throw RestoreError.notACopy }
    }

    private func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Everything in the copy, weighed. The records are most of it.
    public var bytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }

    /// "4 agents", for the line that tells two copies apart.
    public var agentsLine: String {
        agents.isEmpty ? String(l10n: "no agents")
            : agents.count == 1 ? String(l10n: "\(agents.count) agent") : String(l10n: "\(agents.count) agents")
    }

    /// The agents in the copy, named, or nil when there are none. The owner knows his own fleet by its names.
    public var agentNames: String? {
        agents.isEmpty ? nil : agents.map { $0.agentLabel }.joined(separator: ", ")
    }

    /// Whether the hub that made this copy had said these records were sound; nil when it had not checked yet.
    public var recordsSound: Bool? { integrity.map { $0 == "ok" } }

    /// The machines whose vault store key no copy can carry, in one line, or nil for a fleet that holds none.
    ///
    /// This is the one loss a restore cannot undo and does not announce itself: the logins a machine's own broker
    /// made, including passwords of accounts `create_login` opened that the owner never saw, are readable only
    /// with a key that stays on that machine at mode 600.
    public var vaultLine: String? {
        let holders = (vault ?? [:]).filter { $0.value.machine != nil }
        guard !holders.isEmpty else { return nil }
        let machines = Set(holders.values.compactMap(\.machine)).sorted()
        let names = machines.map { $0.capitalized }.joined(separator: ", ")
        return machines.count == 1
            ? String(l10n: "The logins \(names)'s own vault made stay on that server: no copy can carry its store key.")
            : String(l10n: "The logins the vaults of \(names) made stay on those servers: no copy carries a store key.")
    }
}

// MARK: - what he must reconnect afterwards

/// What a restored fleet has not got, and what to do about each, from the copy's own `hub_only`.
///
/// A restored fleet has its records and its configuration. It has none of the credentials the old hub kept on its
/// own disk, because the copy deliberately carries no password, token or key anywhere. The end of a restore is the
/// moment to say so, in the order that unblocks the fleet fastest: the GitHub App key first, because it is one
/// file and every task that touches code stops without it.
///
/// Each line says the same thing `RESTORE.md` says, shortened to what fits beside a button. `RESTORE.md` is the
/// one that has to work without the app, so it keeps the long form.
public struct RestoreAfterwards: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let place: Place
    }
    /// The page of this app that settles the step, when one does.
    public enum Place: Sendable, Equatable {
        case apps, mcps
        /// Nothing in the app puts this back. Saying so is the honest action; a button that does nothing is not.
        case nowhere
    }

    public let steps: [Step]
    /// The line for a copy whose hub had none of the four, which is the ordinary small fleet — or, for a copy
    /// from a hub older than `hub_only`, the line that says this copy does not say.
    public let nothing: String?
    /// Whether the copy said what its hub held. A copy from before `hub_only` says nothing, and a list built out
    /// of silence would read as "there is nothing to reconnect", which is the one thing it does not mean.
    public let knows: Bool

    public init(_ held: FleetManifest.HubOnly?) {
        guard let held else {
            steps = []
            knows = false
            nothing = String(l10n: "This copy does not say what its hub kept on its own disk — it was made by a hub from before that line. A restored fleet never carries the hub's own sign-ins, so check each of them: the GitHub App key first, then Google, then any MCP server.")
            return
        }
        knows = true
        var steps: [Step] = []
        var noGitHub = false, noGoogle = false, noMCP = false
        if held.github_app?.present == true {
            steps.append(Step(
                title: String(l10n: "A GitHub App key"),
                detail: String(l10n: "This one first: it is one file and it unblocks every task that touches code. GitHub never gives a key out twice, so make a new one for your App and paste it with the App ID. Your repositories are in the copy, so the App you want is the one installed on them."),
                place: .apps))
        } else {
            noGitHub = true
        }
        if let google = held.google, google.present, google.accounts != 0 || google.client == true {
            let accounts = google.accounts
            let detail = accounts.map {
                $0 == 1
                    ? String(l10n: "Until it is back, every Drive and Gmail tool of every agent stops. Your files and your mail are untouched — this is a sign-in. The copy names your Google account and which agent had which level, so nothing has to be remembered. You need the Desktop client file again.")
                    : String(l10n: "Until it is back, every Drive and Gmail tool of every agent stops. Your files and your mail are untouched — this is a sign-in. The copy names your \($0) Google accounts and which agent had which level, so nothing has to be remembered. You need the Desktop client file again.")
            } ?? String(l10n: "Until it is back, every Drive and Gmail tool of every agent stops. Your files and your mail are untouched — this is a sign-in. The copy names your Google accounts and which agent had which level, so nothing has to be remembered. You need the Desktop client file again.")
            steps.append(Step(
                title: String(l10n: "Google, one account at a time"),
                detail: detail,
                place: .apps))
        } else {
            noGoogle = true
        }
        if let mcp = held.mcp, mcp.present, mcp.servers != 0 {
            let detail = mcp.servers.map {
                $0 == 1
                    ? String(l10n: "The one MCP server you connected are signed in on the old server. Until each is connected again, the agents that had those tools are told the server is not connected. The copy names the servers and their addresses.")
                    : String(l10n: "The \($0) MCP servers you connected are signed in on the old server. Until each is connected again, the agents that had those tools are told the server is not connected. The copy names the servers and their addresses.")
            } ?? String(l10n: "The MCP servers you connected are signed in on the old server. Until each is connected again, the agents that had those tools are told the server is not connected. The copy names the servers and their addresses.")
            steps.append(Step(
                title: String(l10n: "Each MCP server"),
                detail: detail,
                place: .mcps))
        } else {
            noMCP = true
        }
        if let files = held.attachments, files.present {
            let count = files.files ?? 0
            steps.append(Step(
                title: String(l10n: "The files you attached to messages"),
                detail: count == 1
                    ? String(l10n: "\(count) file on the old hub server, left out on purpose: they are your own files and the hub throws them away itself after ninety days. The messages keep their text; an attachment that will not open is the whole of the loss.")
                    : String(l10n: "\(count) files on the old hub server, left out on purpose: they are your own files and the hub throws them away itself after ninety days. The messages keep their text; an attachment that will not open is the whole of the loss."),
                place: .nowhere))
        }
        self.steps = steps
        if steps.isEmpty {
            nothing = String(l10n: "When this copy was made your hub had no GitHub App, no Google account, no connected MCP server and no attached file, so there is nothing of that kind to put back.")
        } else {
            switch (noGitHub, noGoogle, noMCP) {
            case (true, false, false): nothing = String(l10n: "Your hub had no GitHub App, so there is nothing of those to put back.")
            case (false, true, false):
                nothing = String(l10n: "Your hub had no Google account connected, so there is nothing of those to put back.")
            case (false, false, true):
                nothing = String(l10n: "Your hub had no MCP server connected, so there is nothing of those to put back.")
            case (true, true, false):
                nothing = String(l10n: "Your hub had no GitHub App and no Google account connected, so there is nothing of those to put back.")
            case (true, false, true):
                nothing = String(l10n: "Your hub had no GitHub App and no MCP server connected, so there is nothing of those to put back.")
            case (false, true, true):
                nothing = String(l10n: "Your hub had no Google account connected and no MCP server connected, so there is nothing of those to put back.")
            case (true, true, true):
                nothing = String(l10n: "Your hub had no GitHub App and no Google account connected and no MCP server connected, so there is nothing of those to put back.")
            case (false, false, false): nothing = nil
            }
        }
    }

    public init(_ manifest: FleetManifest) { self.init(manifest.hub_only) }
}

extension RestoreAfterwards.Place {
    /// What the button says, or nil where there is nothing to press.
    public var label: String? {
        switch self {
        case .apps: String(l10n: "Open Apps")
        // The MCP servers are a group of Settings › Apps.
        case .mcps: String(l10n: "Open Apps")
        case .nowhere: nil
        }
    }
}

// MARK: - what the hub already holds

/// What a hub already holds, as far as this app can count it from `/ui/state`.
///
/// It is shown when the route answers 409 because this hub has worked, and it is **not** what decides that: the
/// hub counts tasks, goals, needs, owner reports, conversations, duties and wake-up rules, and `/ui/state` carries
/// only the first four. So this says what it can see and says that the hub also counted what it cannot — a hub
/// whose only work is one duty refuses the restore while this struct is empty, and the owner must not be told he
/// is replacing nothing.
public struct FleetHolds: Sendable, Equatable {
    public let agents: Int
    public let tasks: Int
    public let goals: Int
    public let needs: Int
    public let reports: Int

    public init(agents: Int, tasks: Int, goals: Int, needs: Int, reports: Int) {
        self.agents = agents; self.tasks = tasks; self.goals = goals; self.needs = needs; self.reports = reports
    }

    public init(_ state: HubState) {
        self.init(agents: state.agents.count, tasks: state.tasks.count, goals: state.goals?.count ?? 0,
                  needs: state.needs.count, reports: state.reports.count)
    }

    /// Nothing this app can see. The hub may still be counting something of its own, which is why the sentence
    /// below never says "nothing".
    public var seesNothing: Bool { tasks == 0 && goals == 0 && needs == 0 && reports == 0 }

    /// What putting a copy over this hub would take away, in his words.
    public var says: String {
        var parts: [String] = []
        if tasks > 0 { parts.append(tasks == 1 ? String(l10n: "\(tasks) task") : String(l10n: "\(tasks) tasks")) }
        if goals > 0 { parts.append(goals == 1 ? String(l10n: "\(goals) goal") : String(l10n: "\(goals) goals")) }
        if needs > 0 {
            parts.append(needs == 1 ? String(l10n: "\(needs) thing that needed you") : String(l10n: "\(needs) things that needed you"))
        }
        if reports > 0 { parts.append(reports == 1 ? String(l10n: "\(reports) report") : String(l10n: "\(reports) reports")) }
        let seen = parts.isEmpty ? "" : String(l10n: "This hub holds \(sentence(parts)).") + " "
        return seen + String(l10n: "It also counts conversations, duties and wake-up rules, which this list does not show. The copy replaces all of it. The records it puts aside are kept on the hub server beside the new ones, and only the one set: a second replacement writes over them.")
    }

    private func sentence(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return String(l10n: "\(parts.dropLast().joined(separator: ", ")) and \(parts[parts.count - 1])")
    }
}

// MARK: - whether it is offered at all

extension HubState {
    /// Owner feature `restore`: `POST /ui/restore` on its own, and not the two copy routes, which `health` gates.
    /// A hub from before this half of owner API 1.5 serves those and not this one, so the app offers nothing a
    /// hub cannot do.
    public var putsACopyBack: Bool { ui_features?.contains("restore") == true }
}

/// Where the app offers to put a copy back, and where it says nothing.
public enum RestoreOffer {
    /// At the end of the first-run wizard: begin a new fleet, or restore one. This is the moment that matters,
    /// because on the day he needs it he is standing in front of a fresh hub and not hunting through Settings.
    ///
    /// A hub this Mac has just claimed always gets the choice. A hub it was only pointed at — "I already have
    /// one" — gets it when there is plainly nothing on it: one agent, which is the manager its own installer
    /// wrote, and no work. A fleet he is simply reconnecting to does not, and has it on System status.
    public static func atClaim(_ state: HubState?, claimed: Bool) -> Bool {
        guard let state, state.putsACopyBack else { return false }
        return claimed || (state.agents.count <= 1 && FleetHolds(state).seesNothing)
    }

    /// On System status, beside Save a copy: wherever the hub serves the route. This is the way back that
    /// `RESTORE.md` promises inside every copy, so it is not conditional on the hub looking empty — the 409 is
    /// what stands between a working fleet and a copy, and it asks him first.
    public static func inHealth(_ state: HubState?) -> Bool { state?.putsACopyBack == true }
}

/// Which of two things a 409 from `POST /ui/restore` was.
///
/// The route answers 409 for a generation that moved under the send and for a hub that already holds a fleet's
/// work, and the words beside the status are prose this app does not read. So it asks the hub again and decides
/// on what it reads, exactly as every other stale-base 409 in this app is decided (`HubError.conflict`).
public enum RestoreConflict: Sendable, Equatable {
    /// The hub moved on while the copy was going up. Nothing was written; read again and send again.
    case staleGeneration
    /// This hub already holds a fleet's work, and here is as much of it as `/ui/state` shows.
    case holdsWork(FleetHolds)
    /// The hub did not answer the second question either, so which of the two this was is not known. It is
    /// treated as the careful one: he is asked before anything replaces anything.
    case unknown

    public static func read(sentWith database: String, now: HubState?) -> RestoreConflict {
        guard let now else { return .unknown }
        return now.db == database ? .holdsWork(FleetHolds(now)) : .staleGeneration
    }

    /// What this hub holds, where that is known.
    public var holds: FleetHolds? {
        if case .holdsWork(let holds) = self { return holds }
        return nil
    }
}

// MARK: - waiting for it to land

/// The wait after a restore is accepted: the hub stages the records, restarts itself, and the start that follows
/// moves them into place and gives the fleet a new `db`.
///
/// A changed `db` is the one signal that the restore landed, and it is a sound one: a hub makes a new `db_id` only
/// when it took a staged copy, never on an ordinary restart. So the hub going quiet is **not** a failure while
/// this is running, and the app must not say it is; and the app must not say the restore worked until that `db`
/// has really moved.
public struct RestoreWatch: Sendable, Equatable {
    /// What one read of `/ui/state` found.
    public enum Look: Sendable, Equatable {
        /// The hub did not answer. Expected: it is restarting.
        case unreachable
        /// It answered, with this generation.
        case answered(String)
    }
    public enum Stand: Sendable, Equatable {
        /// The hub is away, or is still the one that took the copy. Nothing is wrong.
        case restarting
        /// The `db` moved: the records are in place and this is the new generation.
        case landed(String)
        /// This hub does not restart itself (`restarting: false`). The copy is staged beside its database and the
        /// next start takes it, so the owner has one thing left to do and it is not in this app.
        case staged
        /// Long enough that something is wrong. The copy may still be staged, so the answer is to look, not to
        /// send it again blindly — and sending it again is safe only because the request id makes it a replay.
        case lost
    }

    public let before: String
    /// What the hub answered in `restarting`. False only on a fleet that turned the hub's restart command off.
    public let restarts: Bool
    /// How long a restart may take before the app stops calling it a restart. A hub restart is seconds; this is
    /// long enough for a slow machine and short enough that he is not left watching a spinner.
    public static let patience: Double = 240

    public init(before: String, restarts: Bool) {
        self.before = before; self.restarts = restarts
    }

    public func read(_ look: Look, waited: Double) -> Stand {
        // A generation that moved wins over everything, including the deadline: the restore landed, however long
        // the machine took about it.
        if case .answered(let now) = look, now != before, !now.isEmpty { return .landed(now) }
        if !restarts { return .staged }
        return waited > Self.patience ? .lost : .restarting
    }
}

// MARK: - reading one member out of the copy

/// One member of a zip, by name, without reading the zip into memory.
///
/// A copy is up to 256 MiB and `fleet.json` is a few hundred bytes at the end of it, so this seeks: the end of
/// central directory, then the entry, then its own bytes. It reads the central directory and one member and
/// nothing else, and it refuses a member larger than the caller allows.
///
/// It is here rather than in a package because the app needs exactly this: one small member of one file that the
/// hub itself wrote, with the hub reading every byte of the same file again before it acts on any of it.
enum ZipArchive {
    enum Trouble: Error { case notAZip, noSuchMember, tooLarge, damaged }

    /// Every member's name, in central directory order.
    static func names(in file: URL) throws -> [String] {
        try entries(in: file).map(\.name)
    }

    /// One member's bytes.
    static func member(_ name: String, in file: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let entry = try entries(handle: handle).first(where: { $0.name == name }) else {
            throw Trouble.noSuchMember
        }
        guard entry.size <= limit else { throw Trouble.tooLarge }
        // The local header repeats the name and may carry an extra field of another length than the central
        // directory's, so where the bytes start is read from the local header itself.
        try handle.seek(toOffset: entry.at)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              number(header, 0, 4) == 0x0403_4b50 else { throw Trouble.damaged }
        let start = entry.at + 30 + number(header, 26, 2) + number(header, 28, 2)
        try handle.seek(toOffset: start)
        guard let packed = try handle.read(upToCount: Int(entry.packed)), packed.count == Int(entry.packed) else {
            throw Trouble.damaged
        }
        switch entry.method {
        case 0: guard packed.count == entry.size else { throw Trouble.damaged }; return packed
        case 8: return try inflate(packed, to: entry.size)
        default: throw Trouble.damaged
        }
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let packed: UInt64
        let size: Int
        /// Where this member's own local header is.
        let at: UInt64
    }

    private static func entries(in file: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try entries(handle: handle)
    }

    /// The central directory, read whole. A copy carries a manifest, the records and the owner's own files, so
    /// this is kilobytes; a directory larger than four mebibytes is not a copy of a fleet.
    private static func entries(handle: FileHandle) throws -> [Entry] {
        let total = try handle.seekToEnd()
        guard total >= 22 else { throw Trouble.notAZip }
        // The end of central directory record, which the zip comment can push up to 65,535 bytes from the end.
        let tailLength = UInt64(min(total, 22 + 65_535))
        try handle.seek(toOffset: total - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            throw Trouble.notAZip
        }
        var end = -1
        var at = tail.count - 22
        while at >= 0 {
            if number(tail, at, 4) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Trouble.notAZip }
        let count = Int(number(tail, end + 10, 2))
        let size = number(tail, end + 12, 4)
        let offset = number(tail, end + 16, 4)
        // Zip64 puts 0xFFFFFFFF here and the real figures elsewhere. The hub's copies are never that, so this
        // refuses rather than guesses.
        guard offset != 0xFFFF_FFFF, size != 0xFFFF_FFFF, count <= 20_000,
              size <= 4 << 20, offset + size <= total else { throw Trouble.notAZip }
        try handle.seek(toOffset: offset)
        guard let directory = try handle.read(upToCount: Int(size)), directory.count == Int(size) else {
            throw Trouble.notAZip
        }
        var found: [Entry] = []
        var cursor = 0
        while found.count < count {
            guard cursor + 46 <= directory.count, number(directory, cursor, 4) == 0x0201_4b50 else {
                throw Trouble.notAZip
            }
            let nameLength = Int(number(directory, cursor + 28, 2))
            let extraLength = Int(number(directory, cursor + 30, 2))
            let commentLength = Int(number(directory, cursor + 32, 2))
            let packed = number(directory, cursor + 20, 4)
            let plain = number(directory, cursor + 24, 4)
            let where_ = number(directory, cursor + 42, 4)
            guard cursor + 46 + nameLength <= directory.count,
                  packed != 0xFFFF_FFFF, plain != 0xFFFF_FFFF, where_ != 0xFFFF_FFFF,
                  where_ + packed <= total,
                  let name = String(data: directory.subdata(in: (directory.startIndex + cursor + 46)
                                                            ..< (directory.startIndex + cursor + 46 + nameLength)),
                                    encoding: .utf8) else { throw Trouble.notAZip }
            found.append(Entry(name: name, method: UInt16(number(directory, cursor + 10, 2)),
                               packed: packed, size: Int(plain), at: where_))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return found
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` is in Apple's framework.
    private static func inflate(_ packed: Data, to size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            packed.withUnsafeBytes { source -> Int in
                guard let to = destination.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Trouble.damaged }
        return out
    }

    /// **One small member more, at the end of the zip**, when the zip carries none of that name: its bytes go where the
    /// central directory stood, stored as they are, and the directory follows with one entry more. A write that stops
    /// halfway leaves no zip, so the caller gives a file of its own, which nobody else reads yet (`OwnerAccess.withKey`).
    /// False when the name is there already.
    @discardableResult
    static func add(_ data: Data, named name: String, to file: URL, at date: Date = Date()) throws -> Bool {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        guard try !entries(handle: handle).contains(where: { $0.name == name }) else { return false }
        let total = try handle.seekToEnd()
        let tailLength = UInt64(min(total, 22 + 65_535))
        try handle.seek(toOffset: total - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            throw Trouble.notAZip
        }
        var end = tail.count - 22
        while end >= 0, number(tail, end, 4) != 0x0605_4b50 { end -= 1 }
        guard end >= 0 else { throw Trouble.notAZip }
        let count = number(tail, end + 10, 2), size = number(tail, end + 12, 4), offset = number(tail, end + 16, 4)
        let commentLength = Int(number(tail, end + 20, 2))
        let nameBytes = Data(name.utf8)
        // One disk, no zip64 and room for one entry more: what `entries` took, and the limits of the plain format.
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0, number(tail, end + 8, 2) == count,
              count < 0xFFFF, end + 22 + commentLength <= tail.count, !nameBytes.isEmpty, nameBytes.count <= 255,
              data.count <= 1 << 20, offset + size + UInt64(2 * (46 + nameBytes.count) + data.count) < 0xFFFF_FFFF
        else { throw Trouble.damaged }
        try handle.seek(toOffset: offset)
        guard let directory = try handle.read(upToCount: Int(size)), directory.count == Int(size) else {
            throw Trouble.notAZip
        }
        // The length of the zip's own comment, and the comment: the end of the record, which stays as it was.
        let comment = tail.subdata(in: (tail.startIndex + end + 20)..<(tail.startIndex + end + 22 + commentLength))
        let (day, time) = dosStamp(date)
        // Version 2.0, the name in UTF-8 (bit 11), stored (method 0), then the time, the check and the two sizes.
        let facts = bytes(20, 2) + bytes(0x0800, 2) + bytes(0, 2) + bytes(time, 2) + bytes(day, 2)
            + bytes(UInt64(crc32(data)), 4) + bytes(UInt64(data.count), 4) + bytes(UInt64(data.count), 4)
            + bytes(UInt64(nameBytes.count), 2) + bytes(0, 2)
        let local = bytes(0x0403_4b50, 4) + facts + nameBytes + data
        // Made on a Unix system, so the entry carries the file's mode: a file for its owner alone, as `ssh` asks of a key.
        let entry = bytes(0x0201_4b50, 4) + bytes(0x031E, 2) + facts + bytes(0, 2) + bytes(0, 2) + bytes(0, 2)
            + bytes(UInt64(0o100600) << 16, 4) + bytes(offset, 4) + nameBytes
        let closing = bytes(0x0605_4b50, 4) + bytes(0, 2) + bytes(0, 2) + bytes(count + 1, 2) + bytes(count + 1, 2)
            + bytes(size + UInt64(entry.count), 4) + bytes(offset + UInt64(local.count), 4) + comment
        try handle.truncate(atOffset: offset)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: local + directory + entry + closing)
        try handle.synchronize()
        return true
    }

    /// The check of a member's bytes that every zip carries (CRC-32).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// A date as a zip writes it: the day and the time of day, each in sixteen bits, in two-second steps.
    private static func dosStamp(_ date: Date) -> (day: UInt64, time: UInt64) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt64(max(1980, min(2107, parts.year ?? 1980)) - 1980)
        let day = year << 9 | UInt64(parts.month ?? 1) << 5 | UInt64(parts.day ?? 1)
        let time = UInt64(parts.hour ?? 0) << 11 | UInt64(parts.minute ?? 0) << 5 | UInt64((parts.second ?? 0) / 2)
        return (day, time)
    }

    /// A number in `length` bytes, little endian, as the zip format writes every number.
    private static func bytes(_ value: UInt64, _ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    /// `length` bytes at `at`, little endian, as the zip format writes every number.
    private static func number(_ data: Data, _ at: Int, _ length: Int) -> UInt64 {
        guard at >= 0, at + length <= data.count else { return 0 }
        var value: UInt64 = 0
        for step in 0..<length {
            value |= UInt64(data[data.startIndex + at + step]) << (8 * step)
        }
        return value
    }
}

// MARK: - the copy on this Mac, read

public enum RestoreError: LocalizedError, Sendable, Equatable {
    case notACopy
    case otherFormat(Int)
    case tooLarge
    case empty
    case cannotRead(String)
    /// The hub answered 409 and its generation had not moved, so this hub already holds a fleet's work.
    case holdsWork(String)

    public var errorDescription: String? {
        switch self {
        case .notACopy: String(l10n: "That file is not a copy of a fleet. Choose the zip your hub gave you.")
        case .otherFormat(let format):
            String(l10n: "That copy is format \(format) and this app reads format \(FleetManifest.format1).")
        case .tooLarge: String(l10n: "A copy is at most 256 MiB. Put this one back on the hub server itself.")
        case .empty: String(l10n: "That file is empty.")
        case .cannotRead(let reason): String(l10n: "That copy could not be read: \(reason)")
        case .holdsWork(let said): said
        }
    }
}

/// One copy the owner chose, on his own disk, read far enough to say what it is.
public struct ChosenCopy: Sendable, Equatable {
    public let file: URL
    public let bytes: Int64
    public let manifest: FleetManifest

    public init(file: URL, bytes: Int64, manifest: FleetManifest) {
        self.file = file; self.bytes = bytes; self.manifest = manifest
    }

    /// What must be reconnected once this copy is in place.
    public var afterwards: RestoreAfterwards { RestoreAfterwards(manifest) }

    /// Reads the copy's own manifest, and nothing else of it. Local: the hub reads the whole file again and is
    /// what decides.
    public static func read(_ file: URL) throws -> ChosenCopy {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.int64Value
        guard let size else { throw RestoreError.cannotRead(String(l10n: "this Mac cannot read that file.")) }
        guard size > 0 else { throw RestoreError.empty }
        guard size <= FleetCopy.sizeLimit else { throw RestoreError.tooLarge }
        let manifest: FleetManifest
        do {
            let found = try ZipArchive.member(FleetManifest.manifestMember, in: file, limit: 1 << 20)
            manifest = try JSONDecoder().decode(FleetManifest.self, from: found)
        } catch let trouble as RestoreError {
            throw trouble
        } catch {
            throw RestoreError.notACopy
        }
        try manifest.check()
        // Every member the manifest lists has to be in the zip. The hub checks each one's digest as well; this is
        // only so that a copy that was cut short is refused here instead of after 256 MiB went over the network.
        let carried = Set((try? ZipArchive.names(in: file)) ?? [])
        guard manifest.files.keys.allSatisfy(carried.contains) else { throw RestoreError.notACopy }
        return ChosenCopy(file: file, bytes: size, manifest: manifest)
    }
}

// MARK: - sending it

/// What `POST /ui/restore` answers.
public struct RestoreReceipt: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let fleet_id: String
    public let made_at: Double?
    public let records_bytes: Int64
    /// Everything the copy carries.
    public let files: [String]
    /// The configuration files this restore actually wrote. Empty is the ordinary case for yesterday's copy going
    /// back onto the machine it was taken from.
    public let changed: [String]
    /// The ones this machine had and the copy has not.
    public let removed: [String]
    public let keep_replaced: Bool
    /// Whether the hub will restart itself to take the records. False only where that command is turned off.
    public let restarting: Bool
    /// This request id had already done this, so nothing happened a second time.
    public let replayed: Bool?
}

extension HubClient {
    /// `POST /ui/restore`: the copy goes back.
    ///
    /// The file is streamed from disk, so a 256 MiB copy never stands in this app's memory. The request id is the
    /// caller's and must stay the same across a retry of the same send: the hub replays the first answer for the
    /// same id with the same copy, which is what makes a retry after a lost connection safe. **A send with a
    /// different `replace` is a different command to the hub**, so changing it needs a new id.
    ///
    /// The hub restarts about two seconds after it answers, so a send can also fail in transport with the restore
    /// already accepted. That is why the caller watches the generation rather than believing this call's error.
    public func restore(copy file: URL, hub: URL, database: String, client: String, requestID: UUID,
                        replace: Bool) async throws -> RestoreReceipt {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/restore"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
            + (replace ? [URLQueryItem(name: "replace", value: "yes")] : [])
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.setValue(requestID.uuidString.lowercased(), forHTTPHeaderField: "X-Fleet-Request-Id")
        // A copy takes as long as it takes to go up, as `takeCopy` lets it take as long as it takes to come down.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        let transfer = URLSession(configuration: configuration)
        defer { transfer.finishTasksAndInvalidate() }
        let (data, response) = try await transfer.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard http.statusCode == 200 else {
            throw HubError.refusal(http.statusCode, HubClient.words(in: data))
        }
        let receipt = try JSONDecoder().decode(RestoreReceipt.self, from: data)
        guard receipt.ok, receipt.records_bytes > 0 else { throw HubError.invalidResponse }
        return receipt
    }
}
