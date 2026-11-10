import Foundation
import Testing
@testable import FleetCore

struct GoalProfileTests {
    private let hub = URL(string: "http://localhost:8765")!

    /// Nothing writes a goal's limits any more (UI-API.md 1.20), but a goal written before carries them and the
    /// Goals page still reads the money limit beside the recorded spending.
    @Test func theStoredLimitsOfAGoalStillReadBack() throws {
        #expect(MoneyLimit(amount: Decimal(string: "12.34")!, currency: "EUR").isValid)
        #expect(!MoneyLimit(amount: Decimal(string: "12.345")!, currency: "EUR").isValid)
        #expect(!MoneyLimit(amount: -1, currency: "EUR").isValid)
        #expect(!GoalLimits(tokens: 0).isValid)
        let fields: [String: Any] = [
            "id": 3, "title": "Synthetic goal", "text": "Local check", "state": "active", "revision": 1, "spent": 0,
            "created": 1000, "updated": 1000, "request_id": UUID().uuidString.lowercased(),
            "limits": ["money": ["amount": 100, "currency": "EUR"], "tokens": NSNull(), "deadline": NSNull(),
                       "not_to_do": ["No paid ads"]]]
        let goal = try JSONDecoder().decode(FleetGoal.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(goal.isValid && goal.isOpen)
        #expect(goal.limits.money == MoneyLimit(amount: 100, currency: "EUR"))
        #expect(goal.limits.not_to_do == ["No paid ads"])
    }

    @Test func profileSecretRefusalClearsTheSavedRequestText() throws {
        let canary = "SYNTHETIC-PROFILE-SECRET-123"
        let input = ProfileInput(sections: ["character", "responsible_for", "may_do", "must_ask"].map {
            ProfileSection(key: $0, title: $0.replacingOccurrences(of: "_", with: " "), text: "Local \(canary)")
        })
        #expect(input.isValid)
        let request = PendingRequest(hub: hub, database: "db", client: "local", command: .profile(agent: "vps", sha256: String(repeating: "a", count: 64)), text: try input.payload())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = Outbox(file: directory.appendingPathComponent("pending.json"))
        try outbox.save(request)
        #expect(try outbox.load()?.body() == request.body())
        let suite = "fleet.profile.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["vps": "Local \(canary)"], forKey: "agentDrafts")
        _ = try outbox.rejectSecret(matching: request.requestID, drafts: defaults)
        let loaded = try #require(try outbox.load())
        #expect(loaded.requestID == request.requestID && loaded.command == request.command)
        #expect(loaded.text.isEmpty && loaded.refusal != nil)
        #expect(try !String(contentsOf: outbox.file, encoding: .utf8).contains(canary))
        #expect(defaults.dictionary(forKey: "agentDrafts") == nil)
    }
    @Test func profileStructureAndWireSizeAreCheckedBeforeSaving() throws {
        let input = ProfileInput(sections: [ProfileSection(key: "character", title: "Character", text: "Local")])
        #expect(!input.isValid)
        let request = PendingRequest(hub: hub, database: "db", client: "local", text: String(repeating: "💡", count: 20_000))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try Outbox(file: file).save(request) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
