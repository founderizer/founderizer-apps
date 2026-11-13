import Foundation
import Testing
@testable import FleetCore

/// The connected apps of the hub's remote MCP address (UI-API.md, version 1.133): the reading of `GET /ui/connect`, the
/// words of a row, and the two owner commands with their requests and receipts. Example names only.
struct ConnectedAppsTests {
    private func hub(_ answer: OneAnswer) -> URL { URL(string: "http://127.0.0.1:\(answer.port)")! }

    private func state(_ fields: [String: Any]) throws -> ConnectState {
        try JSONDecoder().decode(ConnectState.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func connection(id: Int = 1, name: String = "Claude", level: String = "read", lastUsed: Any = NSNull(),
                            created: Double = 1_000) -> [String: Any] {
        ["id": id, "name": name, "level": level, "last_used": lastUsed, "created": created]
    }

    private func reading(address: Any = "https://hub-1.tail1234.ts.net/mcp", connections: [[String: Any]] = [],
                         db: String = "db") -> [String: Any] {
        ["db": db, "on": true, "address": address, "connections": connections, "gate": ["version": "1", "ok": true]]
    }

    // MARK: the reading

    @Test func theReadingTakesTheHubsAnswer() throws {
        let read = try state(reading(connections: [connection(), connection(id: 2, name: "ChatGPT", level: "act",
                                                                             lastUsed: 2_000)]))
        try read.validate(database: "db")
        #expect(read.on && read.address == "https://hub-1.tail1234.ts.net/mcp" && read.gate?.ok == true)
        #expect(read.connections.map(\.name) == ["Claude", "ChatGPT"])
        #expect(read.connections[0].last_used == nil && read.connections[1].last_used == 2_000)
        // A hub that does not know its name yet gives no address, and that is still a reading.
        try state(reading(address: NSNull())).validate(database: "db")
    }

    /// `can_turn_on` (UI-API.md, version 1.151): read when the hub gives it, and false from a hub before that version.
    @Test func canTurnOnIsReadAndFalseWithoutTheField() throws {
        #expect(try state(reading()).canTurnOn == false)
        var off = reading()
        off["on"] = false
        off["can_turn_on"] = true
        let offer = try state(off)
        try offer.validate(database: "db")
        #expect(offer.canTurnOn && !offer.on)
        off["can_turn_on"] = false
        #expect(try state(off).canTurnOn == false)
        // `stopped`: the hub's reason while it is on and does not work; absent or null is none.
        #expect(try state(off).stopped == nil)
        off["stopped"] = NSNull()
        #expect(try state(off).stopped == nil)
        off["stopped"] = "the hub cannot read the Tailscale serve status"
        #expect(try state(off).stopped == "the hub cannot read the Tailscale serve status")
        #expect(ConnectedApps.offer == "connect_offer")
    }

    @Test func turnOnAndTurnOffAreOneCommandOfTheSetting() async throws {
        let id = UUID()
        let answer = try OneAnswer(status: "200 OK") { _ in
            #"{"on":false,"revoked":2,"revision":"abc","sha256":"def","ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        let off = try await HubClient().connectSettings(hub: hub(answer), database: "db", client: "c", requestID: id, on: false)
        #expect(!off.on && off.revoked == 2)
        let sent = String(decoding: answer.received, as: UTF8.self)
        #expect(sent.hasPrefix("POST /ui/connect/settings HTTP/1.1\r\n"))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: answer.received)) as? [String: Any])
        #expect(body["on"] as? Bool == false && body["db"] as? String == "db")
        // An answer for the other setting is not taken.
        let other = try OneAnswer(status: "200 OK") { _ in
            #"{"on":true,"revoked":0,"revision":"abc","sha256":"def","ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().connectSettings(hub: hub(other), database: "db", client: "c", requestID: id, on: false)
        }
    }

    @Test func aReadingThatIsNotTheHubsContractIsRefused() throws {
        #expect(throws: HubError.self) { try state(reading(db: "other")).validate(database: "db") }
        #expect(throws: HubError.self) { try state(reading(connections: [connection(), connection()])).validate(database: "db") }
        #expect(throws: HubError.self) { try state(reading(connections: [connection(level: "admin")])).validate(database: "db") }
        #expect(throws: HubError.self) { try state(reading(connections: [connection(id: 0)])).validate(database: "db") }
        for address in ["http://hub-1.tail1234.ts.net/mcp", "https://hub-1.tail1234.ts.net/", "https://hub-1.tail1234.ts.net:8765/mcp",
                        "https://user@hub-1.tail1234.ts.net/mcp", "https://hub-1.tail1234.ts.net/mcp?x=1", "mcp"] {
            #expect(throws: HubError.self) { try state(reading(address: address)).validate(database: "db") }
        }
    }

    // MARK: the words of a row

    @Test func aRowSaysItsLevelAndItsLastUse() throws {
        let used = try state(reading(connections: [connection(lastUsed: 10_000 - 7_200)])).connections[0]
        #expect(ConnectedApps.detail(used, now: 10_000) == "Read · 2 h ago")
        // Before a first use, the time since it was made.
        let new = try state(reading(connections: [connection(level: "act", created: 10_000 - 300)])).connections[0]
        #expect(ConnectedApps.detail(new, now: 10_000) == "Act · 5 min ago")
        #expect(ConnectedApps.levelWord("read") == "Read" && ConnectedApps.levelWord("act") == "Act")
    }

    // MARK: the requests

    @Test func theReadAsksForThisGeneration() async throws {
        let answer = try OneAnswer(status: "200 OK") { _ in
            #"{"db":"db","on":true,"address":"https://hub-1.tail1234.ts.net/mcp","connections":[],"gate":{"version":null,"ok":false}}"#
        }
        let read = try await HubClient().connectState(hub: hub(answer), database: "db")
        #expect(read.connections.isEmpty && read.gate?.version == nil)
        #expect(answer.received.starts(with: Data("GET /ui/connect?db=db HTTP/1.1\r\n".utf8)))
    }

    /// A hub of this release answers 409 (and an older one 404): the read throws, so the page shows nothing of it.
    @Test func aHubWithoutTheFeatureGivesNoReading() async throws {
        let refused = try OneAnswer(status: "409 Conflict") { _ in #"{"error":"Connected apps are not in this release of the hub."}"# }
        await #expect(throws: HubError.self) { try await HubClient().connectState(hub: hub(refused), database: "db") }
        let missing = try OneAnswer(status: "404 Not Found") { _ in #"{"error":"not found"}"# }
        await #expect(throws: HubError.self) { try await HubClient().connectState(hub: hub(missing), database: "db") }
    }

    @Test func aCodeIsOneCommandAtItsLevel() async throws {
        let id = UUID()
        let answer = try OneAnswer(status: "200 OK") { _ in
            #"{"code":"ABCD-EFGH-JKLM","level":"act","expires":1600.5,"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        let code = try await HubClient().connectCode(hub: hub(answer), database: "db", client: "c", requestID: id, level: "act")
        #expect(code.code == "ABCD-EFGH-JKLM" && code.level == "act" && code.expires == 1600.5)
        let sent = String(decoding: answer.received, as: UTF8.self)
        #expect(sent.hasPrefix("POST /ui/connect/code HTTP/1.1\r\n"))
        #expect(sent.contains("X-Fleet-Client: c"))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: answer.received)) as? [String: String])
        #expect(body == ["level": "act", "db": "db", "request_id": id.uuidString.lowercased()])
    }

    /// The hub's code is three groups of four; two groups (a hub before the security review) read too, and nothing else.
    @Test func aCodeHasTheHubsShape() {
        #expect(ConnectedApps.isCode("ABCD-EFGH-JKLM") && ConnectedApps.isCode("ABCD-EFGH"))
        for other in ["ABCD", "abcd-efgh-jklm", "ABCD-EFGH-JKLM-NPQR", "ABCDEFGHJKLM", "ABCD-EFGH-JKL", " ABCD-EFGH-JKLM"] {
            #expect(!ConnectedApps.isCode(other))
        }
    }

    @Test func aCodeAnswerThatIsNotThisRequestsIsRefused() async throws {
        let id = UUID()
        // Another level than the one asked for.
        let other = try OneAnswer(status: "200 OK") { _ in
            #"{"code":"ABCD-EFGH","level":"act","expires":1600,"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().connectCode(hub: hub(other), database: "db", client: "c", requestID: id, level: "read")
        }
        // Another request's receipt.
        let foreign = try OneAnswer(status: "200 OK") { _ in
            #"{"code":"ABCD-EFGH","level":"read","expires":1600,"ok":true,"request_id":"\#(UUID().uuidString.lowercased())","client":"c","replayed":false}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().connectCode(hub: hub(foreign), database: "db", client: "c", requestID: id, level: "read")
        }
        // A code that is not of the hub's shape is not taken.
        let malformed = try OneAnswer(status: "200 OK") { _ in
            #"{"code":"ABCD-EFGH-JK","level":"read","expires":1600,"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().connectCode(hub: hub(malformed), database: "db", client: "c", requestID: id, level: "read")
        }
        // A repeat gives no code: the answer reads, and the page then has no code to show.
        let repeated = try OneAnswer(status: "200 OK") { _ in
            #"{"code":null,"level":"read","expires":1600,"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":true}"#
        }
        let none = try await HubClient().connectCode(hub: hub(repeated), database: "db", client: "c", requestID: id, level: "read")
        #expect(none.code == nil && none.replayed)
        // A level that the hub does not have never leaves this Mac.
        await #expect(throws: HubError.self) {
            try await HubClient().connectCode(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "c", level: "admin")
        }
    }

    @Test func revokeIsOneCommandOnTheConnectionsPath() async throws {
        let id = UUID()
        let answer = try OneAnswer(status: "200 OK") { _ in
            #"{"id":7,"revoked":true,"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"c","replayed":false}"#
        }
        let ended = try await HubClient().connectRevoke(hub: hub(answer), database: "db", client: "c", requestID: id, id: 7)
        #expect(ended.revoked && ended.id == 7)
        let sent = String(decoding: answer.received, as: UTF8.self)
        #expect(sent.hasPrefix("POST /ui/connect/7/revoke HTTP/1.1\r\n") && sent.contains("X-Fleet-Client: c"))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: answer.received)) as? [String: String])
        #expect(body == ["db": "db", "request_id": id.uuidString.lowercased()])
        // The hub's 404 for a connection that is not open is a refusal.
        let gone = try OneAnswer(status: "404 Not Found") { _ in #"{"error":"no such open connection"}"# }
        await #expect(throws: HubError.self) {
            try await HubClient().connectRevoke(hub: hub(gone), database: "db", client: "c", id: 7)
        }
    }
}
