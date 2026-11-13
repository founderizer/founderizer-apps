import Foundation

/// **How the fleet itself says one machine is reached**, so that the app asks the owner for none of it.
///
/// Every part of it is already in the hub's own report of that machine (`GET /ui/machines`): `address` is the
/// machine's private address, and `access.ssh` is the user and the port the fleet has on record for it, from
/// `team.json`. A page that asks the owner to type an address it is holding is asking him a question it can
/// answer itself.
///
/// The SSH user is the one part nothing here can derive. A machine whose `access.ssh` is null leaves the fleet
/// with **no connection on record**, and the page says that in those words. A guess would be worse than the gap:
/// it fails at the far end, with a message about the machine instead of about the record that is missing.
public struct MachineReach: Equatable, Sendable {
    /// The machine's private address, as the hub reports it.
    public let address: String?
    /// The user the fleet is reached as, or nil when `team.json` has no `access` entry for this machine.
    public let user: String?
    /// The SSH port of that entry, or nil with it.
    public let port: Int?

    public init(address: String?, user: String? = nil, port: Int? = nil) {
        self.address = address; self.user = user; self.port = port
    }

    /// The fleet's record for one machine, out of the readings of the agents on it, or nil while the hub has not
    /// reported that machine at all. Nil and "no connection on record" are two different answers, and the page
    /// says only the second of them.
    public static func of(_ machine: String, in readings: [MachineStatus]) -> MachineReach? {
        guard let reading = readings.first(where: { $0.machine == machine }) else { return nil }
        let ssh = reading.access?.ssh
        return MachineReach(address: reading.address, user: ssh?.user, port: ssh?.port)
    }

    /// A whole connection, or nil while the fleet is missing any part of one. A port outside 1…65535 and a user
    /// that is not a user name are read as missing, because the hub's record is data and not an instruction.
    public var onRecord: (address: String, user: String, port: Int)? {
        guard let address, !address.isEmpty, let user,
              user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              let port, (1...65535).contains(port) else { return nil }
        return (address, user, port)
    }

    /// **The one line the owner reads before he presses the button**: how this Mac will reach the machine, in his
    /// own terms. It takes the connection that will really be used, so a connection he gave himself reads the
    /// same way as the fleet's own.
    public static func sentence(machine: String, user: String, address: String, port: Int,
                                identityFile: String?) -> String {
        if let identityFile {
            let file = URL(fileURLWithPath: identityFile).lastPathComponent
            return port == 22 ? String(l10n: "Founderizer reaches \(machine) as \(user) at \(address), with the key \(file).")
                : String(l10n: "Founderizer reaches \(machine) as \(user) at \(address) on port \(port), with the key \(file).")
        }
        return port == 22 ? String(l10n: "Founderizer reaches \(machine) as \(user) at \(address), with the key your SSH agent holds.")
            : String(l10n: "Founderizer reaches \(machine) as \(user) at \(address) on port \(port), with the key your SSH agent holds.")
    }

    /// **A kept connection, at an address that still answers.** The installers let SSH into a Linux machine of a fleet
    /// over the private network only (`hubsetup.py firewall`, 2 November 2026), so a connection this Mac kept with the
    /// public address the owner typed at an install no longer arrives. It goes to the private address the fleet
    /// reports for the machine instead, with its own user, port and key. A name, a LAN address and a private address
    /// stay as they are: only a public address is known not to answer.
    public func reaching(_ kept: InstallTarget) -> InstallTarget {
        guard let address, ClaimCode.isPrivateAddress(address), InstallTarget.isPublicAddress(kept.host) else { return kept }
        var target = kept
        target.host = address
        return target
    }

    /// What the page says of a machine the fleet reports without an `access` entry: the gap in the record, in the
    /// fleet's own terms, and the one thing the owner can do about it here.
    public static func nothingOnRecord(_ machine: String) -> String {
        String(l10n: "The fleet has no connection to \(machine) on record: it knows no SSH user for that server. Give the one you reach it with.")
    }
}

/// **Putting a machine's connection on record** (`POST /ui/team/access`, owner feature `machine_access`).
///
/// A connection the owner gives this app stays in this app: `InstallTargets` keeps it in the defaults of this Mac,
/// where the hub never sees it, no agent reads it and a new Mac starts again with nothing. The fleet's own record
/// is `team.json`'s `access` map, and until this route every writer of it wrote at creation time and never again:
/// the hub installer for the hub's own machine, a server's join (`root`, and only where the join line reported a
/// Linux SSH port), and the local onboarding executor. So a Mac that joined got no entry at all. The Studio stood
/// in the record with no connection while the owner reached it as its own user every day: reachable in fact and
/// unreachable on paper, which is what his instruction of 19 October 2026 is about ("we can't lose access to the
/// fleet and its servers!").
///
/// The form is three fields, and only one of them is a question: the port is 22 and Screen Sharing is off unless
/// he says otherwise, and the user is the one thing nothing here can derive.
public struct MachineAccessForm: Equatable, Sendable {
    public static let feature = "machine_access"
    /// The hub's own rule, so the app refuses what the route would refuse instead of sending it: `hub.SSH_USER`.
    public static let userPattern = "^[A-Za-z_][A-Za-z0-9._-]{0,31}$"

    public var user: String
    public var port: String
    public var screenSharing: Bool

    public init(user: String = "", port: String = "22", screenSharing: Bool = false) {
        self.user = user; self.port = port; self.screenSharing = screenSharing
    }

    /// **Whether this machine is one the owner is asked about at all.** The hub must serve the route, and the
    /// fleet must have no SSH user for the machine: a connection already on record is the state nothing new is
    /// drawn for, which is the owner's own rule of 20 October 2026 — no row that reports only that everything is
    /// fine. So the control is there exactly where there is something to ask for.
    public static func isAsked(of reading: MachineStatus?, features: [String]?) -> Bool {
        guard let reading, features?.contains(feature) == true else { return false }
        return reading.access?.ssh == nil
    }

    public var trimmedUser: String { user.trimmingCharacters(in: .whitespaces) }
    public var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }

    /// Nil when the form is ready to send; otherwise the one line that says what is wrong with it, in his terms.
    public var problem: String? {
        if trimmedUser.isEmpty { return String(l10n: "Give the user you reach this server as.") }
        if trimmedUser.range(of: Self.userPattern, options: .regularExpression) == nil {
            return String(l10n: "A user name is up to 32 characters: a letter or _ first, then letters, digits, . _ or -.")
        }
        guard let port = portNumber, (1...65535).contains(port) else { return String(l10n: "A port is a number from 1 to 65535.") }
        return nil
    }

    public var isValid: Bool { problem == nil }

    /// **What the hub will refuse before it is sent**, so the owner is not told by a 409 what the app already knew:
    /// the fleet may be recorded as `root`, or as the OS user that machine's own helper reports its agents run as,
    /// and as nothing else (`hub.machine_readiness`, `ssh_user_not_allowed`). A machine whose helper has reported
    /// no user has nothing to compare against, so the owner's own word stands.
    public func notAllowed(workerUser: String?) -> String? {
        guard let workerUser, !workerUser.isEmpty, !["root", workerUser].contains(trimmedUser) else { return nil }
        return String(l10n: "The agents of this server run as \(workerUser), so the fleet can reach it as root or as \(workerUser). Another user would leave the server on record as one Founderizer may not use.")
    }
}

/// The hub's answer to `POST /ui/team/access`: the entry that is on record now, or none after a removal.
public struct MachineAccessReceipt: Decodable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let ssh_user: String
        public let ssh_port: Int
        public let screen_sharing: Bool?
    }
    public let ok: Bool
    public let request_id: String
    public let machine: String
    public let access: Entry?
    public let revision: String
    public let sha256: String
    public let changed: Bool
    public let deleted: Bool
}
