import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **"The hub hit an error" on System status has Help improve Founderizer beside Report a problem while the hub's switch
/// of that name is off, and the button opens Settings › Help, where the switch stands** (the owner, 25 November 2026:
/// "show a button there to be able to go to the telemetry setting t send it automatically"). The stand-in hub gives the
/// health with the hub's own fault and the switch's reading. The bugs that it catches: the button while the switch is on,
/// and a button that opens another place than the switch.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct HubFaultReportsTests {
    struct Seen: Sendable {
        let fault: Bool
        let button: Bool
        let opened: String
        let theSwitch: Bool
    }

    @Test func whileTheSwitchIsOffItsButtonOpensSettingsHelpAtTheSwitch() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 120) { try Self.look(send: false, press: true) }
        #expect(seen.fault, "System status shows the hub's own fault")
        #expect(seen.button, "the fault's block has Help improve Founderizer while the switch is off")
        #expect(seen.opened == "\(Destination.settings(.help))", "the button opens Settings › Help")
        #expect(seen.theSwitch, "Settings › Help shows the switch Help improve Founderizer")
        #expect(screen.stayedHis)
    }

    @Test func whileTheSwitchIsOnTheFaultHasNoSuchButton() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 120) { try Self.look(send: true, press: false) }
        #expect(seen.fault, "System status shows the hub's own fault")
        #expect(!seen.button, "no Help improve Founderizer while the switch is on")
        #expect(screen.stayedHis)
    }

    /// System status of a hub with its own fault and the switch at `send`; with `press`, a press of the button.
    @MainActor private static func look(send: Bool, press: Bool) throws -> Seen {
        let database = "hub-fault-\(UUID().uuidString)"
        let state: [String: Any] = [
            "schema_version": 1, "db": database, "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": ["health", ErrorReportsState.feature]]
        let reading = try JSONSerialization.data(withJSONObject: state)
        let hub = try LoopbackHub(state: reading)
        defer { hub.stop() }
        let health: [String: Any] = [
            "db": database, "ok": false, "time": Date().timeIntervalSince1970, "hub": ["integrity": [String: Any]()],
            "helpers": [Any](), "warnings": [["kind": "hub_fault", "detail": "3 times since 14:53."]]]
        let reports: [String: Any] = ["send": send, "db": database]
        hub.give(try JSONSerialization.data(withJSONObject: health), at: "/ui/health")
        hub.give(try JSONSerialization.data(withJSONObject: reports), at: "/ui/error-reports")
        _ = ViewHost.store(try HubState.decode(reading))       // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.isFresh }
        store.destination = .settings(.status)
        let window = ViewHost.window(store)
        defer { ViewHost.close(window) }
        let fault = try ViewHost.middle(of: FleetHealth.Warning(kind: "hub_fault", detail: "").title, in: window) != nil
        // the switch's reading is in, and the page drew it
        ViewHost.turn(15) { (store.reading(ErrorReportsModel.name) as ErrorReportsState?) != nil }
        let label = FleetHealth.Warning.Act.openReports.label
        let button = try ViewHost.middle(of: label, in: window, seconds: send ? 3 : 20)
        guard press, let button else { return Seen(fault: fault, button: button != nil, opened: "", theSwitch: false) }
        // The pictures of the card for a person's look, only when a run asks for them: with the Mac in Light mode and
        // in Dark mode (the app draws dark in both).
        if let pictures = ProcessInfo.processInfo.environment["FOUNDERIZER_PICTURES"] {
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: look)
                ViewHost.turn(1)
                try Self.picture(of: window, to: pictures, as: "hub-fault-system-status-mac-\(name).png")
            }
            NSApp.appearance = nil
        }
        ViewHost.atOnce(ViewHost.click(button, in: window))
        ViewHost.turn(5) { store.destination != .settings(.status) }
        // the switch's own row: its detail line, which no other row has
        let theSwitch = try ViewHost.middle(of: "Sends error codes", in: window) != nil
        if let pictures = ProcessInfo.processInfo.environment["FOUNDERIZER_PICTURES"] {
            try Self.picture(of: window, to: pictures, as: "hub-fault-button-opens-help.png")
        }
        return Seen(fault: fault, button: true, opened: "\(store.destination)", theSwitch: theSwitch)
    }

    /// The window's picture as it draws now, as a PNG file in the folder.
    @MainActor private static func picture(of window: NSWindow, to folder: String, as name: String) throws {
        guard let view = window.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ViewHost.Missing(description: "no picture of the window")
        }
        view.cacheDisplay(in: view.bounds, to: picture)
        guard let png = picture.representation(using: .png, properties: [:]) else {
            throw ViewHost.Missing(description: "no PNG of the window")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}
