import Foundation
import Testing
@testable import FleetCore

/// What a first run reads off this Mac's own Tailscale: the network's devices, a free worker-N name, and the fleet
/// that already runs on it.
struct FleetOnTailscaleTests {
    static let status = """
    {"BackendState": "Running",
     "Self": {"DNSName": "sams-macbook.tail1234.ts.net.", "TailscaleIPs": ["100.101.100.180", "fd7a:115c:a1e0::1"]},
     "Peer": {
       "a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"], "Online": false},
       "b": {"DNSName": "worker-2.tail1234.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.96.10.20"], "Online": true},
       "c": {"DNSName": "iphone.tail1234.ts.net.", "TailscaleIPs": ["100.101.100.90"], "Online": true},
       "d": {"DNSName": "", "TailscaleIPs": ["100.64.0.9"], "Online": true}
     }}
    """

    @Test func theDevicesAreReadByTheirNameInTailscale() {
        let devices = FleetOnTailscale.devices(in: Self.status)
        #expect(devices.map(\.name) == ["iphone", "worker-1", "worker-2"])
        #expect(devices.first { $0.name == "worker-2" }?.address == "100.96.10.20")
        #expect(FleetOnTailscale.ownName(in: Self.status) == "sams-macbook")
        #expect(FleetOnTailscale.devices(in: "not json").isEmpty)
    }

    @Test func aNewServerGetsTheFirstWorkerNameThatNoDeviceHas() {
        #expect(FleetOnTailscale.freeName(in: Self.status) == "worker-3")
        #expect(FleetOnTailscale.freeName(in: Self.status, also: ["worker-3"]) == "worker-4")
        #expect(FleetOnTailscale.freeName(in: "{}") == "worker-1")
    }

    @Test func onlineDevicesAreAskedFirst() {
        let asked = FleetOnTailscale.candidates(in: Self.status).map(\.absoluteString)
        #expect(asked.count == 3)
        #expect(asked.last == "http://100.96.100.130:8765")
    }

    #if os(macOS)
    @Test func theFleetThatAnswersIsFoundAndNoAnswerFindsNone() async {
        let found = await FleetOnTailscale.findHub(json: Self.status) { $0.host == "100.96.10.20" }
        #expect(found?.absoluteString == "http://100.96.10.20:8765")
        let none = await FleetOnTailscale.findHub(json: Self.status) { _ in false }
        #expect(none == nil)
        let offNetwork = await FleetOnTailscale.findHub(json: "{}") { _ in true }
        #expect(offNetwork == nil)
    }
    #endif
}
