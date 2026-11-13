#if os(macOS)
import Foundation

/// **The words of the list in which the owner chooses a server he has at a provider, or a new one** (the owner's yes
/// of 5 November 2026 to the list of existing servers and to the step that asks before a server is made). From what the
/// provider says of each server alone: the check of a chosen server says the rest, as for any other VPS.
extension CloudExisting {
    /// **Why this server cannot take an install of `job`**, in a few words, or nil when it can as far as its provider
    /// says. `fleet`: the names of the fleet's own servers, in lower case.
    public func unfit(for job: InstallJob, fleet: Set<String>) -> String? {
        if fleet.contains(name.lowercased()) { return String(l10n: "In your fleet") }
        if madeFor == "hub" || madeFor == "agent" { return String(l10n: "Used by Founderizer") }
        if !running { return String(localized: "Off (a server)", defaultValue: "Off", bundle: Localized.bundle, locale: Localized.digits) }
        if ipv4 == nil { return String(l10n: "No IPv4 address") }
        let need = job == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        if let memoryMB, memoryMB < need.megabytes { return String(l10n: "\(Self.size(memoryMB)): too small") }
        if let system, let version, !Self.takes(job, system, version) {
            let name = (InstallPlan.systems(.hub) + InstallPlan.systems(.join)).first { $0.id == system }?.name
                ?? system.capitalized
            return job == .hub && Self.takes(.join, system, version) ? String(l10n: "\(name) \(version): not yet for a hub")
                : String(l10n: "\(name) \(version): not supported")
        }
        return nil
    }

    /// Its row's detail: the type at Hetzner, the memory, the system, and the project at DigitalOcean
    /// ("CX23 · 4 GB · Ubuntu 24.04").
    public var summary: String {
        var parts: [String] = []
        if !type.isEmpty, !type.contains("-") { parts.append(type.uppercased()) }
        if let memoryMB { parts.append(Self.size(memoryMB)) }
        if let system, let version {
            let name = (InstallPlan.systems(.hub) + InstallPlan.systems(.join)).first { $0.id == system }?.name
                ?? system.capitalized
            parts.append("\(name) \(version)")
        }
        if let project { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    static func takes(_ job: InstallJob, _ system: String, _ version: String) -> Bool {
        InstallPlan.systems(job).contains { $0.id == system && $0.version == version }
    }

    /// "4 GB", "1.5 GB", "512 MB".
    static func size(_ megabytes: Int) -> String {
        if megabytes < 1024 { return "\(megabytes) MB" }
        if megabytes % 1024 == 0 { return "\(megabytes / 1024) GB" }
        return String(format: "%.1f GB", Double(megabytes) / 1024)
    }
}

extension CloudOffer {
    /// "CX23 · 2 vCPU · 4 GB · 40 GB": the type at Hetzner, then what it is made of.
    public var size: String {
        var parts: [String] = []
        if provider == .hetzner { parts.append(type.uppercased()) }
        if let cores { parts.append("\(cores) vCPU") }
        if let memoryGB { parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded()))) }
        if let diskGB { parts.append("\(diskGB) GB") }
        return parts.joined(separator: " · ")
    }

    /// "€5.49 a month", in this Mac's own way of writing an amount.
    public var monthly: String {
        let format = NumberFormatter()
        format.numberStyle = .currency
        format.currencyCode = currency
        format.maximumFractionDigits = 2
        let amount = format.string(from: monthlyPrice as NSDecimalNumber) ?? "\(monthlyPrice) \(currency)"
        return String(l10n: "\(amount) a month")
    }

    /// The new server's row in the list: "CX23 · 4 GB · Nuremberg · €5.49 a month".
    public var row: String {
        var parts: [String] = []
        if provider == .hetzner { parts.append(type.uppercased()) }
        if let memoryGB { parts.append(CloudExisting.size(Int((memoryGB * 1024).rounded()))) }
        parts.append(String(place.split(separator: ",").first ?? Substring(place)))
        parts.append(monthly)
        return parts.joined(separator: " · ")
    }
}
#endif
