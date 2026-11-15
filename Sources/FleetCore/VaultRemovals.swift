import Foundation

/// **The servers that the owner removed on this Mac** (package 4 of the vault's gates), by fleet: each machine with when
/// it was removed, and whether its unpin still waits.
///
/// The app signs no pin of such a machine again, by a re-sign or by a first trust (`VaultPlan`). So a hub that is broken
/// into cannot keep a removed server's pin alive by keeping that server in its reading: this Mac no longer signs it, and
/// each broker refuses it 90 days after its time. Only Add server for that machine on this Mac clears its mark.
///
/// It holds no key (the manager's choice of 13 November 2026): a trusted machine with no mark always gets the step of
/// today, which reads the machine's key itself. So a record that is lost, or the empty record of a new Mac, ends no pin
/// without a word. A removal that another Mac or the owner's MCP tool made is not in it. The file holds names and times
/// only, in the app's own folder in Application Support.
public struct VaultRemovals: Codable, Equatable, Sendable {
    public struct Mark: Codable, Equatable, Sendable {
        /// When the owner removed the server on this Mac.
        public var at: Double
        /// The unpin of its machine has not reached the central vault yet: the app sends it again until it does.
        public var unpin: Bool

        public init(at: Double, unpin: Bool) { self.at = at; self.unpin = unpin }
    }

    /// By fleet id, then by machine.
    public private(set) var fleets: [String: [String: Mark]]

    public init(fleets: [String: [String: Mark]] = [:]) { self.fleets = fleets }

    /// The marks of one fleet.
    public func marks(fleet: String) -> [String: Mark] { fleets[fleet] ?? [:] }

    /// The owner removed `machine` on this Mac at `at`. `unpin`: its unpin is still to be sent.
    public mutating func removed(_ machine: String, fleet: String, at: Double, unpin: Bool) {
        fleets[fleet, default: [:]][machine] = Mark(at: at, unpin: unpin)
    }

    /// The central vault took the unpin of `machine`. The mark stays: the machine gets no pin until Add server.
    public mutating func unpinned(_ machine: String, fleet: String) {
        fleets[fleet]?[machine]?.unpin = false
    }

    /// Add server for `machine` on this Mac: its mark goes, and it gets the trust step of a new server again.
    public mutating func added(_ machine: String, fleet: String) {
        fleets[fleet]?[machine] = nil
        if fleets[fleet]?.isEmpty == true { fleets[fleet] = nil }
    }

    /// The machines of `fleet` whose unpin is due at `now`: a mark whose unpin waits, with no failed try of it in the last
    /// `VaultTries.wait`. An unpin never gives up, and it has no row.
    public func unpinsDue(fleet: String, tries: [String: VaultTries], now: Double) -> [String] {
        marks(fleet: fleet).filter { machine, mark in
            mark.unpin && (tries[machine].map { now - $0.last >= VaultTries.wait } ?? true)
        }.keys.sorted()
    }

    /// The file of this Mac's record: in the app's own folder, beside its other files.
    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Founderizer/vault-removals.json")
    }

    /// The record in `file`, or an empty one when there is none or it cannot be read: the same as a new Mac's.
    public static func load(_ file: URL = Self.file) -> VaultRemovals {
        guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Self.self, from: data) else {
            return VaultRemovals()
        }
        return record
    }

    /// Writes the record to `file` in one step, so a stop in the middle leaves the record before or after.
    public func save(_ file: URL = Self.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
