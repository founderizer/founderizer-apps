import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **One press of Add server's "Make the server"** (F3 of the owner's feedback of 22 November 2026, piece 2), through the
/// engine that the page calls: a stand-in hub, and a provider's stand-in that counts the calls. The app's real build runs
/// up to its wait for the new server, with no keychain, no key file, no network of this Mac and no real provider.
@Suite(.serialized, .timeLimit(.minutes(10))) struct AddServerEngineTests {
    /// **Akamai's API as one server needs it**: two plans that fit, free in each region, a firewall and one Linode. It
    /// keeps each call. Synthetic data only.
    private final class ProviderCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []

        func count(_ call: String) -> Int { lock.withLock { kept.filter { $0 == call }.count } }

        var exchange: ProviderExchange {
            { [self] request in
                let url = request.url!
                let call = "\(request.httpMethod ?? "GET") \(url.path)"
                lock.withLock { kept.append(call) }
                return (Data(Self.answer(call).utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        private static func answer(_ call: String) -> String {
            if call.hasSuffix("/availability") {
                return #"[{"region":"x","plan":"g6-standard-1","available":true},"#
                    + #"{"region":"x","plan":"g6-standard-2","available":true}]"#
            }
            switch call {
            case "GET /v4/linode/types":
                return #"{"data":[{"id":"g6-standard-1","label":"x","class":"standard","vcpus":1,"memory":2048,"disk":51200,"#
                    + #""price":{"hourly":0.0075,"monthly":12.0},"region_prices":[],"successor":null},"#
                    + #"{"id":"g6-standard-2","label":"x","class":"standard","vcpus":2,"memory":4096,"disk":81920,"#
                    + #""price":{"hourly":0.036,"monthly":24.0},"region_prices":[],"successor":null}],"page":1,"pages":1}"#
            case "POST /v4/networking/firewalls": return #"{"id":88712,"label":"x","status":"enabled"}"#
            case "POST /v4/linode/instances":
                return #"{"id":4711,"label":"x","status":"provisioning","ipv4":["198.51.100.88"]}"#
            case "GET /v4/linode/instances/4711": return #"{"id":4711,"status":"running","ipv4":["198.51.100.88"]}"#
            default: return "{}"
            }
        }
    }

    /// A provider's token of a test: no keychain.
    private struct TestToken: CredentialShelf {
        func read() -> Data? { Data("NOTAREALTOKEN0123456789".utf8) }
        func keep(_ data: Data) throws {}
    }

    @MainActor private final class Ended { var press = false }

    /// What one press came to: the servers that the provider was asked for, the build's stage, the line over the press,
    /// and the servers that this Mac then kept as made for its hub.
    private struct Pressed: Sendable {
        let posts: Int
        let makes: Bool
        let words: String?
        let kept: [String: String]
    }

    /// One press, with a hub that answers or one that nobody runs (port 9 of this Mac). `heard` runs as the hub's list
    /// comes, and `goesOn` is the page's answer.
    private static func press(hubAnswers: Bool, goesOn: Bool = true,
                              heard: @escaping @MainActor @Sendable (FleetCloudModel) -> Void = { _ in }) async throws -> Pressed {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 60) { () -> Pressed in
            let state = try ViewHost.reading(needs: [], features: [])
            var store = ViewHost.store(state)
            let hub = try LoopbackHub(state: Data("{}".utf8))
            hub.give(Data(#"{"db":"\#(state.db)","time":0,"servers":[]}"#.utf8), at: "/ui/servers")
            defer { hub.stop() }
            if hubAnswers {
                AppDefaults.store.set(hub.address, forKey: "hubAddress")
                store = FleetStore()
                store.state = state
            }
            let calls = ProviderCalls()
            let model = FleetCloudModel(outside: .init(
                servers: { CloudServers(provider: $0, exchange: calls.exchange, shelf: TestToken(), pause: { _ in }) },
                publicKey: { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAo/DN+NoNbdAzU3DYGLTD7ne5vXT9bm+oEyoiacxwWg founderizer-test" },
                joinKey: { _ in "tskey-auth-kAUTH1234CNTRL-notarealkey" },
                network: { "{}" }))
            let engine = AddServerEngine(store: store, model: model)
            defer { model.cancel() }                                // the build's wait for the server ends with the test
            model.open(.akamai, use: .agent, lists: false)
            guard ViewHost.turn(15, until: { model.offer != nil }) else {
                throw ViewHost.Missing(description: "the provider's offer did not come")
            }
            let ended = Ended()
            Task {
                await engine.press(heard: { _ in heard(model) }, goesOn: { goesOn }, then: { _ in })
                ended.press = true
            }
            guard ViewHost.turn(15, until: { ended.press }) else {
                throw ViewHost.Missing(description: "the press did not end")
            }
            // A press that makes a server began its build before it ended: the build goes on to the provider's answer.
            let makes = model.stage != .choosing
            if makes { ViewHost.turn(15) { model.stage == .joining } }
            return Pressed(posts: calls.count("POST /v4/linode/instances"), makes: makes, words: model.failure,
                           kept: MadeServers.kept(hub: store.hub))
        }
        #expect(screen.stayedHis)
        return seen
    }

    /// **One press makes one server, once the hub answered**, and this Mac keeps it as made for that hub. A move that lost
    /// the build, made it twice or forgot the record ("Use this server" would not know the server again) fails here.
    @Test func onePressAsksTheProviderForOneServer() async throws {
        let pressed = try await Self.press(hubAnswers: true)
        #expect(pressed.posts == 1 && pressed.makes)
        #expect(Array(pressed.kept.values) == ["4711"], "\(pressed.kept)")
        #expect(pressed.words == nil)
    }

    /// **A hub that does not answer makes none**, and its words stand over the press (the owner's report of 14 November
    /// 2026: a server was made and paid for, and its install could not start). A bug that drops the question, that takes a
    /// failed read as an answer, or that goes on after the words fails here.
    @Test func aHubThatDoesNotAnswerMakesNone() async throws {
        let pressed = try await Self.press(hubAnswers: false)
        #expect(pressed.posts == 0 && !pressed.makes)
        #expect(pressed.words?.isEmpty == false)
    }

    /// **A press that was cancelled while the hub was asked makes none**: the press is the page's own task, which ends when
    /// the page closes, and nothing else says so (the model still shows the choice, and the page's answer is yes). A bug
    /// that drops that look rents a server for a page that closed.
    @Test func aPressThatWasCancelledMeanwhileMakesNone() async throws {
        let closed = try await Self.press(hubAnswers: true) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        #expect(closed.posts == 0 && !closed.makes)
        #expect(closed.words == nil)                    // the hub answered: a silent one leaves its words
    }

    /// **A press that its page or its choice took back while the hub was asked makes none**: the page does not show the
    /// choice any more or chose a server of the list, a server of the account was chosen in place of the new one, and a
    /// dearer offer was chosen: exactly the offer that was pressed is made, or none. A bug that drops one of these looks
    /// rents a server that nobody pressed for.
    @Test func aPressThatWasTakenBackMeanwhileMakesNone() async throws {
        let page = try await Self.press(hubAnswers: true, goesOn: false)
        #expect(page.posts == 0 && !page.makes)
        let choice = try await Self.press(hubAnswers: true) { $0.chosen = "4712" }
        #expect(choice.posts == 0 && !choice.makes)
        let other = try await Self.press(hubAnswers: true) { model in
            if model.choices.count > 1 { model.choose(model.choices[1]) }
        }
        #expect(other.posts == 0 && !other.makes)
    }
}
