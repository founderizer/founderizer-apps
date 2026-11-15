import Foundation

/// **Which fleet servers have the owner's access line, as this Mac knows it** (`OwnerAccessModel` in the app): for each
/// server, the fingerprint of the key whose line this Mac put in root's `authorized_keys` there (`OwnerAccess.install`).
/// A mark is kept by the hub's address, the server's name and the server's private address. The fleet gives a new
/// server the name of a server that it removed (worker-1, worker-2, …), and the new server has another private address:
/// so it is not taken for the removed one, and it gets its line too. Until 14 November 2026 a mark had no address, and
/// such a new server never got its line.
///
/// **A mark from before that day** has the hub's address and the server's name only, so it cannot say for which server
/// of that name it was written. That server gets one try in each launch of the app, until a try works: the program
/// changes nothing where the line is in place already, and its answer gives the server a mark with its address. A
/// server that this Mac cannot reach is tried once in a launch for an old mark, not six times (`VaultTries`).
public struct OwnerAccessMarks: Equatable, Sendable {
    /// The name of each mark, and the fingerprint of its key: what the app keeps in its defaults.
    public private(set) var all: [String: String]

    public init(_ all: [String: String] = [:]) { self.all = all }

    /// What a round does with one server.
    public enum Step: Equatable, Sendable {
        /// The line of this key is on this server: nothing.
        case inPlace
        /// Only a mark from before 14 November 2026 names this key for a server of this name: one try in this launch.
        case once
        /// No mark names this key for this server: a try, and more tries after a failure (`VaultTries`).
        case run

        /// The tries after one more failure. A server with an old mark waits for the next launch after one failure.
        public func failed(after earlier: VaultTries?, at now: Double, reason: String) -> VaultTries {
            self == .once ? VaultTries(failures: VaultTries.most, last: now, reason: reason)
                : VaultTries.failed(after: earlier, at: now, reason: reason)
        }
    }

    /// The name of one server's mark: the hub's address, the server's name and its private address, with a space
    /// between them. A server's name has no space (`Servers.namePattern`), so the name of one server's marks never
    /// starts with the name of another server's.
    public static func name(_ machine: String, address: String?, hub: URL) -> String {
        "\(hub.absoluteString) \(machine) \(address ?? "")"
    }

    /// The name of a mark from before 14 November 2026: the hub's address and the server's name only.
    static func oldName(_ machine: String, hub: URL) -> String { "\(hub.absoluteString) \(machine)" }

    /// What a round does with this server for the key of this fingerprint.
    public func step(_ machine: String, address: String?, hub: URL, fingerprint: String) -> Step {
        if all[Self.name(machine, address: address, hub: hub)] == fingerprint { return .inPlace }
        return all[Self.oldName(machine, hub: hub)] == fingerprint ? .once : .run
    }

    /// Keeps the mark of this key for this server. It replaces every earlier mark of a server of this name on this
    /// hub: the old mark, and the marks of other addresses. So there is one mark for each name.
    public mutating func keep(_ fingerprint: String, for machine: String, address: String?, hub: URL) {
        let old = Self.oldName(machine, hub: hub)
        all = all.filter { $0.key != old && !$0.key.hasPrefix(old + " ") }
        all[Self.name(machine, address: address, hub: hub)] = fingerprint
    }
}
