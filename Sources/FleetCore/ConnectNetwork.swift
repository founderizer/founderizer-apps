import Foundation

/// **What the owner's access token does once in his Tailscale network, before connected apps turn on** (the build
/// specification of the MCP address, section 7, step 1; proved on a real network on 13 November 2026).
///
/// The hub's public address is published by Tailscale Funnel on the hub's machine, and Tailscale lets a machine do
/// that only when the network's policy gives it the `funnel` attribute and the network makes HTTPS certificates. The
/// fleet's own key cannot write the policy, so the owner pastes one access token on the key page of Turn on
/// (`ConnectAppKeyStep`), and this Mac does four things with it and keeps nothing of it:
///
///   1. **Two lines of the policy file**, each only where it is missing: `tag:founderizer-hub` in `tagOwners`, and one
///      `nodeAttrs` entry that gives that tag the `funnel` attribute. So only the hub's machine may publish, and no
///      other machine of the fleet. The file is changed as the fleet's own lines are (`FleetPolicy`): bytes are
///      inserted, Tailscale checks the file first, and it is set against the version that was read. A file that
///      another tool keeps is never written: the owner gets the lines to add.
///   2. **The tag on the hub's device**, beside the tags that it has.
///   3. **MagicDNS**, when it is off.
///   4. **HTTPS certificates**, when they are off.
extension TailscaleFleetKey {
    /// The tag of the one machine that may publish an address: the hub's.
    public static let hubTag = "tag:founderizer-hub"

    /// Prepares the network for the hub's public address. `hub` is the host of the hub's address as this Mac calls it:
    /// its address on the private network, or its name there. The answer says that it is done, or gives the policy
    /// lines that the owner adds where another tool keeps the file; he then pastes a token again, and this goes on
    /// from the file as it then stands.
    public func connectNetwork(accessToken: String, hub: String) async throws -> ConnectNetworkAnswer {
        let token = try Self.checkedToken(accessToken)
        let place = try await settings(token)
        // The hub's device first: a token of another network than the hub's changes nothing in that network.
        let device = try await hubDevice(hub, token: token)
        for attempt in 1...2 {
            let policy = try await policy(token)
            guard let needs = FunnelPolicy.needs(in: policy.text) else {
                return .addLines(FunnelPolicy.lines(for: .everything) ?? "")
            }
            if needs.isEmpty { break }
            guard !place.managed, let etag = policy.etag, let written = FunnelPolicy.writing(needs, into: policy.text) else {
                return .addLines(FunnelPolicy.lines(for: needs) ?? "")
            }
            try await validate(written, token: token)
            if try await set(written, etag: etag, token: token) { break }
            guard attempt == 1 else { throw FleetKeyError.policyChangedMeanwhile }
        }
        // The device's tags as they are now, after the policy's write: a tag that it got meanwhile is not dropped.
        let now = try await hubDevice(hub, token: token)
        guard now.id == device.id else { throw ConnectNetworkError.hubNotFound }
        if !now.tags.contains(Self.hubTag) {
            _ = try await send(request("device/\(now.id)/tags", token: token, method: "POST",
                                       json: ["tags": now.tags + [Self.hubTag]]), token: token)
        }
        try await turnOnNames(token)
        return .done
    }

    /// One device of the tailnet, as far as this step reads it.
    struct Device: Equatable {
        let id: String
        let tags: [String]
    }

    /// The hub's device in the token's tailnet: the one device of that tailnet's own that has `hub` as an address or
    /// as its full name. A short name is no proof: another tailnet can have a machine with the same first label, and
    /// this step writes that tailnet's policy. A device that another tailnet shares in (`isExternal`) is not this
    /// tailnet's. None, or more than one, is `ConnectNetworkError.hubNotFound`: a token of another network, or a hub
    /// that this Mac calls by an address that is not its address on the private network. A device with no tag belongs
    /// to a person and not to the fleet, and a tag would take it from that person, so this step does not give it one
    /// (`hubNotTagged`).
    func hubDevice(_ hub: String, token: String) async throws -> Device {
        let data = try await send(request("tailnet/-/devices", token: token), token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [[String: Any]] else { throw FleetKeyError.notUnderstood }
        let wanted = hub.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let found = devices.filter { device in
            let name = ((device["name"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let addresses = ((device["addresses"] as? [String]) ?? []).map { $0.lowercased() }
            return !wanted.isEmpty && device["isExternal"] as? Bool != true && (addresses.contains(wanted) || name == wanted)
        }
        guard found.count == 1, let id = (found[0]["nodeId"] as? String) ?? (found[0]["id"] as? String),
              id.range(of: "^[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil else {
            throw ConnectNetworkError.hubNotFound
        }
        let tags = (found[0]["tags"] as? [String]) ?? []
        guard !tags.isEmpty, tags.allSatisfy({ $0.range(of: "^tag:[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil })
        else { throw ConnectNetworkError.hubNotTagged }
        return Device(id: id, tags: tags)
    }

    /// MagicDNS and HTTPS certificates, each turned on only when the network says that it is off. A network that does
    /// not say (an answer without the field) is left as it is: `hubsetup.py connect on` then says what is missing.
    func turnOnNames(_ token: String) async throws {
        let dns = try await send(request("tailnet/-/dns/preferences", token: token), token: token)
        if let object = try? JSONSerialization.jsonObject(with: dns) as? [String: Any], object["magicDNS"] as? Bool == false {
            _ = try await send(request("tailnet/-/dns/preferences", token: token, method: "POST",
                                       json: ["magicDNS": true]), token: token)
        }
        let settings = try await send(request("tailnet/-/settings", token: token), token: token)
        if let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
           object["httpsEnabled"] as? Bool == false {
            _ = try await send(request("tailnet/-/settings", token: token, method: "PATCH",
                                       json: ["httpsEnabled": true]), token: token)
        }
    }
}

/// Why the token's network cannot be prepared for the hub's public address, where Tailscale itself refused nothing.
public enum ConnectNetworkError: LocalizedError, Equatable, Sendable {
    /// The token's tailnet has no device of its own that is the hub, or more than one.
    case hubNotFound
    /// The hub's device has no tag: it belongs to a person.
    case hubNotTagged

    public var errorDescription: String? {
        switch self {
        case .hubNotFound:
            "Founderizer did not find your hub's server in this access token's Tailscale network."
        case .hubNotTagged:
            "Your hub's server has no tag in Tailscale, so Founderizer cannot let it publish an address."
        }
    }
}

/// **The two policy lines of the hub's public address**: what a file misses of them, the same file with them in it,
/// and the lines as text for a file that this app does not write. It reads and changes the file as `FleetPolicy` does.
enum FunnelPolicy {
    /// What one file misses.
    struct Needs: Equatable, Sendable {
        /// `tag:founderizer-hub` is not in `tagOwners`.
        var tag: Bool
        /// No `nodeAttrs` entry gives that tag, or every machine, the `funnel` attribute.
        var attribute: Bool
        var isEmpty: Bool { !tag && !attribute }
        static let everything = Needs(tag: true, attribute: true)
    }

    /// The tag, owned by the tailnet's admins, as the fleet's own tag is.
    static let tagLine = "\"\(TailscaleFleetKey.hubTag)\": [\"autogroup:admin\"]"
    /// The attribute, for that tag and for nothing else.
    static let attributeLine = "{\"target\": [\"\(TailscaleFleetKey.hubTag)\"], \"attr\": [\"funnel\"]}"

    /// What the file misses, or nil when this app cannot read it.
    static func needs(in text: String) -> Needs? { FleetPolicy.parsed(text).map(needs) }

    /// Keys are read as Tailscale reads them, whatever their case. An entry for every machine (`*`) gives the hub the
    /// attribute too; one for the members of the tailnet (`autogroup:member`) does not, because a machine with a tag
    /// is no member.
    static func needs(_ policy: [String: Any]) -> Needs {
        let members = FleetPolicy.lowered(policy)
        let owners = (members["tagowners"] as? [String: Any]) ?? [:]
        let tag = !owners.keys.contains { $0.lowercased() == TailscaleFleetKey.hubTag }
        let given = FleetPolicy.objects(members["nodeattrs"]).contains { entry in
            let target = FleetPolicy.strings(entry["target"])
            return FleetPolicy.strings(entry["attr"]).contains("funnel")
                && (target.contains(TailscaleFleetKey.hubTag) || target.contains("*"))
        }
        return Needs(tag: tag, attribute: !given)
    }

    /// The file with what it misses inserted, and every byte it had still in it, in order; nil when this app cannot see
    /// where the lines belong. A section that is there gets its line at its start; one that is not is added at the
    /// start of the file's object. The result is read again before it is given back: a file that does not then say
    /// what the hub needs is not sent at all.
    static func writing(_ needs: Needs, into text: String) -> String? {
        var bytes = Array(text.utf8)
        guard !needs.isEmpty, let found = FleetPolicy.scan(bytes) else { return nil }
        var inserts: [(at: Int, text: String)] = []
        var atRoot = ""
        if needs.tag {
            let line = "\n\t\t" + tagLine + ","
            switch found.members["tagowners"] {
            case nil: atRoot += "\n\t\"tagOwners\": {" + line + "\n\t},"
            case let member? where member.opener == UInt8(ascii: "{"): inserts.append((member.at, line))
            default: return nil
            }
        }
        if needs.attribute {
            let line = "\n\t\t" + attributeLine + ","
            switch found.members["nodeattrs"] {
            case nil: atRoot += "\n\t\"nodeAttrs\": [" + line + "\n\t],"
            case let member? where member.opener == UInt8(ascii: "["): inserts.append((member.at, line))
            default: return nil
            }
        }
        if !atRoot.isEmpty { inserts.append((found.root, atRoot)) }
        for insert in inserts.sorted(by: { $0.at > $1.at }) {
            bytes.insert(contentsOf: Array(insert.text.utf8), at: insert.at)
        }
        let written = String(decoding: bytes, as: UTF8.self)
        guard let after = FleetPolicy.parsed(written), Self.needs(after).isEmpty else { return nil }
        return written
    }

    /// The same lines as text, for the owner to add himself, each in the section it belongs to; nil when the file has
    /// both already.
    static func lines(for needs: Needs) -> String? {
        var sections: [String] = []
        if needs.tag { sections.append("\"tagOwners\": {\n\t" + tagLine + ",\n},") }
        if needs.attribute { sections.append("\"nodeAttrs\": [\n\t" + attributeLine + ",\n],") }
        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }
}
