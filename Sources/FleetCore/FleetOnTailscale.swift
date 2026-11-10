import Foundation

/// **What a first run reads off this Mac's own Tailscale** (the onboarding the owner approved on 4 November 2026): the
/// devices of the network, so that a fleet that already runs on it is found with no address typed ("I already have
/// one" goes), and so that a server the app makes gets a name that no device has yet, in the owner's own form,
/// worker-1, worker-2 (the owner, 30 October 2026: "rename them to worker-1, worker-2 and so on, except mac
/// studios/minis").
public enum FleetOnTailscale {
    /// One other device of the network: its name in Tailscale (the first label of its MagicDNS name), its first
    /// private IPv4 address, and whether Tailscale sees it online.
    public struct Device: Equatable, Sendable {
        public let name: String
        public let address: String
        public let online: Bool
    }

    /// The other devices in `tailscale status --json`, by name. A device with no private IPv4 address is left out.
    public static func devices(in json: String) -> [Device] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        return peers.compactMap { node -> Device? in
            let full = ((node["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let name = full.split(separator: ".").first.map(String.init), !name.isEmpty,
                  let address = ((node["TailscaleIPs"] as? [String]) ?? []).first(where: ClaimCode.isPrivateAddress)
            else { return nil }
            return Device(name: name, address: address, online: node["Online"] as? Bool ?? false)
        }
        .sorted { $0.name < $1.name }
    }

    /// The name of this Mac itself in the same answer, so it is never a server's name.
    public static func ownName(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let own = object["Self"] as? [String: Any] else { return nil }
        let full = ((own["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return full.split(separator: ".").first.map(String.init)
    }

    /// The first worker-N that no device of the network is called, and that `also` does not hold: Tailscale would give
    /// a second worker-1 the name worker-1-1, and the fleet takes its servers' names from Tailscale.
    public static func freeName(in json: String, also taken: [String] = []) -> String {
        let names = Set(devices(in: json).map(\.name) + [ownName(in: json)].compactMap { $0 } + taken.map { $0.lowercased() })
        return (1...(names.count + 1)).lazy.map { "worker-\($0)" }.first { !names.contains($0) } ?? "worker-\(names.count + 1)"
    }

    /// The hub's own port on every server of a fleet.
    public static let hubPort = 8765

    /// The addresses to ask for a hub, online devices first: every device of the network may be a fleet's VPS.
    public static func candidates(in json: String) -> [URL] {
        devices(in: json).sorted { $0.online && !$1.online }.compactMap { URL(string: "http://\($0.address):\(hubPort)") }
    }
}

#if os(macOS)
extension FleetOnTailscale {
    /// **A fleet that already runs on this Mac's network**: each device is asked once, at the same time, for the hub's
    /// `/health`, two seconds at most each, and the first that answers is the address to connect to. The app's own
    /// reading of it then says whether that fleet serves this Mac. nil when no device answers, or this Mac is on no
    /// network.
    public static func findHub(json: String? = nil, ask: @escaping @Sendable (URL) async -> Bool = answersHealth) async -> URL? {
        let status: String?
        if let json { status = json } else { status = await MacNetwork.status() }
        guard let status else { return nil }
        let addresses = candidates(in: status)
        guard !addresses.isEmpty else { return nil }
        return await withTaskGroup(of: URL?.self) { group in
            for address in addresses { group.addTask { await ask(address) ? address : nil } }
            for await found in group { if let found { group.cancelAll(); return found } }
            return nil
        }
    }

    /// Whether a hub answers its `/health` at `hub`, in two seconds.
    @Sendable public static func answersHealth(_ hub: URL) async -> Bool {
        var request = URLRequest(url: hub.appendingPathComponent("health"), timeoutInterval: 2)
        request.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
#endif
