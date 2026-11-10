#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The words of the list in which the owner chooses a server he has at a provider, or a new one (the owner's yes of 5
/// November 2026): a short reason on each server that cannot be used, and what each row says.
struct CloudChoiceTests {
    private func server(_ name: String = "web-1", ipv4: String? = "203.0.113.20", type: String = "cx23",
                        memory: Int? = 4096, system: String? = "ubuntu", version: String? = "24.04", running: Bool = true,
                        project: String? = nil, madeFor: String? = nil) -> CloudExisting {
        CloudExisting(id: "1", name: name, ipv4: ipv4, type: type, memoryMB: memory, system: system, version: version,
                      place: "Nuremberg", running: running, project: project, madeFor: madeFor)
    }

    @Test func aServerThatCanTakeTheInstallHasNoReason() {
        #expect(server().unfit(for: .hub, fleet: []) == nil)
        #expect(server().unfit(for: .join, fleet: ["worker-1"]) == nil)
        // A server whose provider does not say its system is left to the check.
        #expect(server(system: nil, version: nil).unfit(for: .join, fleet: []) == nil)
    }

    @Test func eachServerThatCannotBeUsedSaysWhyInAFewWords() {
        #expect(server("Worker-1").unfit(for: .join, fleet: ["worker-1"]) == "In your fleet")
        #expect(server(madeFor: "hub").unfit(for: .join, fleet: []) == "Used by Founderizer")
        #expect(server(madeFor: "agent").unfit(for: .hub, fleet: []) == "Used by Founderizer")
        #expect(server(running: false).unfit(for: .hub, fleet: []) == "Off")
        #expect(server(ipv4: nil).unfit(for: .hub, fleet: []) == "No IPv4 address")
        #expect(server(memory: 1024).unfit(for: .join, fleet: []) == "1 GB: too small")
        #expect(server(memory: 1024).unfit(for: .hub, fleet: []) == nil, "the hub needs about 1 GB")
        #expect(server(memory: 512).unfit(for: .hub, fleet: []) == "512 MB: too small")
        // Both installers take Ubuntu 26.04 and Debian 13 (InstallPlan.joinTakes).
        #expect(server(version: "26.04").unfit(for: .hub, fleet: []) == nil)
        #expect(server(version: "26.04").unfit(for: .join, fleet: []) == nil)
        #expect(server(system: "debian", version: "13").unfit(for: .hub, fleet: []) == nil)
        #expect(server(system: "debian", version: "11").unfit(for: .join, fleet: []) == "Debian 11: not supported")
        #expect(server(system: "centos", version: "9").unfit(for: .hub, fleet: []) == "Centos 9: not supported")
    }

    @Test func eachRowSaysWhatTheServerIs() {
        #expect(server().summary == "CX23 · 4 GB · Ubuntu 24.04")
        #expect(server(type: "s-1vcpu-2gb", memory: 2048, project: "Web").summary == "2 GB · Ubuntu 24.04 · Web")
        #expect(server(memory: 1536, system: nil, version: nil).summary == "CX23 · 1.5 GB")
    }

    @Test func theNewServerSaysWhatItIsWhereAndWhatItCosts() {
        let offer = CloudOffer(provider: .hetzner, type: "cx23", location: "nbg1", cores: 2, memoryGB: 4, diskGB: 40,
                               monthlyPrice: Decimal(string: "5.49")!, currency: "EUR")
        #expect(offer.size == "CX23 · 2 vCPU · 4 GB · 40 GB")
        #expect(offer.place == "Nuremberg, Germany")
        #expect(offer.monthly.hasSuffix(" a month") && offer.monthly.contains("5") && offer.monthly.contains("49"))
        #expect(offer.row == "CX23 · 4 GB · Nuremberg · \(offer.monthly)")
        let ocean = CloudOffer(provider: .digitalOcean, type: "s-1vcpu-2gb", location: "fra1", cores: 1, memoryGB: 2,
                               diskGB: 50, monthlyPrice: 12, currency: "USD")
        #expect(ocean.size == "1 vCPU · 2 GB · 50 GB")
        #expect(ocean.row == "2 GB · Frankfurt · \(ocean.monthly)")
    }
}
#endif
