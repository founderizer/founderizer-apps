import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **A Save copy that failed says so on Settings › Backup** (F14 piece 6, the analysis of the owner's backup feedback
/// of 22 November 2026, claim 28): the page's own button took a copy and, when that failed, the page showed nothing;
/// only System status read the model's failure. Now the failure is the warning of the row Keep a copy automatically,
/// where the automatic copy's failure shows already, in the model's or the hub's own words. The stand-in hub refuses the
/// copy with its 404 of a route that it does not serve ("not here"). The bug that it catches: a press of Save copy that
/// fails with no word on the page where he pressed it.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct BackupSaveFailureTests {
    struct Seen: Sendable {
        let asked: Bool
        let said: Bool
    }

    @Test func aSaveCopyThatFailedSaysSoUnderKeepACopyAutomatically() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            let state: [String: Any] = [
                "schema_version": 1, "db": "backup-\(UUID().uuidString)", "time": Int(Date().timeIntervalSince1970),
                "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
                "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
                "reports": [], "ui_features": ["health", "restore"]]
            let reading = try JSONSerialization.data(withJSONObject: state)
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(reading))       // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite && store.writesNow }
            store.destination = .settings(.backup)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let save = try ViewHost.middle(of: FleetHealth.Warning.Act.saveCopy.label, in: window) else {
                throw ViewHost.Missing(description: "Settings › Backup has no Save copy")
            }
            ViewHost.atOnce(ViewHost.click(save, in: window))
            ViewHost.turn(15) { hub.requests.contains { $0.path == "/ui/backup" } }
            let asked = hub.requests.contains { $0.method == "GET" && $0.path == "/ui/backup" }
            return Seen(asked: asked, said: try ViewHost.middle(of: "not here", in: window) != nil)
        }
        #expect(seen.asked, "the press asked the hub for a copy")
        #expect(seen.said, "the hub's refusal shows on the page")
        #expect(screen.stayedHis)
    }
}
