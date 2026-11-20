import Foundation
import Testing
@testable import FleetCore

/// Report a problem (the owner's words of 18 October 2026). The promise this product sells is that we hold nothing
/// of the customer's, so most of these are about what must **not** be in a report: no task, no agent, no name of
/// his work — and nothing at all that the screen did not show him first.
struct ProblemReportTests {
    private func report(text: String = "The task page scrolled away while I read it.",
                        email: String = "him@example.com",
                        facts: [ProblemReport.Fact] = [.init(name: "Screen", value: "Task")]) -> ProblemReport {
        ProblemReport(text: text, email: email, facts: facts)
    }

    // ------------------------------------------------------------ what is ready to send

    @Test func aReportNeedsWordsAndAnAddress() {
        #expect(report().isReady)
        #expect(!report(text: "   \n ").isReady)
        #expect(!report(email: "him").isReady)
        #expect(!report(email: "").isReady)
    }

    @Test func aReportLongerThanTheSiteTakesIsRefusedHere() {
        let long = String(repeating: "x", count: ProblemReport.maxText + 1)
        #expect(!report(text: long).isReady)
        #expect(report(text: String(repeating: "x", count: ProblemReport.maxText)).isReady)
    }

    @Test func theFormSaysOneThingAtATime() {
        // Nothing written yet is not a refusal: it is a form he has not filled in.
        #expect(report(text: "").refusal == nil)
        #expect(report(email: "him").refusal == "Write the address we should answer at.")
        #expect(report(text: String(repeating: "x", count: ProblemReport.maxText + 1), email: "him").refusal?
            .hasPrefix("That is longer") == true)
        #expect(report().refusal == nil)
    }

    @Test func anAddressNeedsOneAtAndADomain() {
        #expect(ProblemReport.isAddress("a@b.co"))
        #expect(ProblemReport.isAddress(" a@b.co "))
        #expect(!ProblemReport.isAddress("a@b"))
        #expect(!ProblemReport.isAddress("a@@b.co"))
        #expect(!ProblemReport.isAddress("a b@c.co"))
        #expect(!ProblemReport.isAddress("@b.co"))
        #expect(!ProblemReport.isAddress("a@.co"))
        #expect(!ProblemReport.isAddress("a@b.co."))
        #expect(!ProblemReport.isAddress("a@b.co" + String(repeating: "x", count: ProblemReport.maxEmail)))
    }

    // ------------------------------------------------------------ what goes with it

    @Test func theFactsAreTheSixThisMacKnows() {
        let facts = ProblemReport.facts(app: "2026.11.1 (42)", system: "15.3.0", fleet: "0123456789abcdef",
                                        hub: "5a8d395", screen: "Task", trouble: "The hub did not answer.")
        #expect(facts.map(\.name) == ["Founderizer", "macOS", "Fleet", "Hub", "Screen", "Last error"])
        #expect(facts.map(\.value) == ["2026.11.1 (42)", "15.3.0", "0123456789abcdef", "5a8d395", "Task",
                                       "The hub did not answer."])
    }

    @Test func aFullRevisionIsCutToWhatTheRowShows() {
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: nil,
                                        hub: "1f43dab42994b95bf1f7458f683c5b0dd0bb0153", screen: "Task", trouble: nil)
        #expect(facts.first { $0.name == "Hub" }?.value == "1f43dab42994")
    }

    @Test func aFactTheMacCouldNotReadSaysSoAndIsNeverGuessed() {
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: nil, hub: "", screen: "Dashboard",
                                        trouble: nil)
        #expect(facts.first { $0.name == "Fleet" }?.value == "Not reported")
        #expect(facts.first { $0.name == "Hub" }?.value == "Not reported")
        // No error means no row: an empty line is not a fact.
        #expect(!facts.contains { $0.name == "Last error" })
    }

    @Test func theScreenIsAPageNameAndCarriesNoneOfHisWork() {
        #expect(ProblemReport.screenName("task(112)") == "Task")
        #expect(ProblemReport.screenName("agent(\"studio\")") == "Agent chat")
        #expect(ProblemReport.screenName("agentDetail(\"studio\", Founderizer.AgentTab.messages)") == "Agent details")
        #expect(ProblemReport.screenName("server(\"vps-1\")") == "Server")
        #expect(ProblemReport.screenName("dashboard") == "Dashboard")
        #expect(ProblemReport.screenName("addAgent") == "Add agent")
        // Tasks as an agent's chat panel opens it is Tasks, not the board's old name with the agent's.
        #expect(ProblemReport.screenName("activityFrom(\"studio\")") == "Tasks")
        // A page this app has never heard of still gives a name, and still gives no number and no agent.
        #expect(ProblemReport.screenName("somethingNew(7, \"vps\")") == "Something new")
        #expect(ProblemReport.screenName("") == "Founderizer")
    }

    // ------------------------------------------------------------ what leaves the Mac

    @Test func theRequestCarriesOnlyWhatTheScreenShowed() throws {
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: "0123456789abcdef",
                                        hub: "5a8d395", screen: "Task", trouble: nil)
        let body = try report(facts: facts).body()
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["text", "email", "facts"])
        let carried = try #require(sent["facts"] as? [[String: String]])
        #expect(carried.map { $0["name"] ?? "" } == facts.map(\.name))
        #expect(carried.map { $0["value"] ?? "" } == facts.map(\.value))
    }

    @Test func theWordsAreTrimmedAndTheAddressWithThem() throws {
        let body = try report(text: "  it broke  ", email: " him@example.com ").body()
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["text"] as? String == "it broke")
        #expect(sent["email"] as? String == "him@example.com")
    }

    @Test func copyReportSaysExactlyWhatTheSendWouldHaveSaid() {
        let facts = ProblemReport.facts(app: "2026.11.1", system: "15.3.0", fleet: "0123456789abcdef",
                                        hub: "5a8d395", screen: "Task", trouble: nil)
        let lines = report(facts: facts).lines
        for fact in facts { #expect(lines.contains("\(fact.name): \(fact.value)")) }
        #expect(lines.contains("Answer to: him@example.com"))
        #expect(lines.hasSuffix("The task page scrolled away while I read it."))
    }

    // ------------------------------------------------------------ where it goes

    @Test func theReportGoesToTheFleetsOwnChannelAndOursWhenItHasNone() throws {
        #expect(try ProblemReportClient.endpoint(channel: nil).absoluteString == "https://founderizer.com/api/report")
        #expect(try ProblemReportClient.endpoint(channel: "  ").absoluteString == "https://founderizer.com/api/report")
        #expect(try ProblemReportClient.endpoint(channel: "https://staging.founderizer.com").absoluteString
            == "https://staging.founderizer.com/api/report")
    }

    @Test func aChannelThisAppCannotReachIsRefusedBeforeAnythingLeaves() {
        for bad in ["ftp://founderizer.com", "https://", "not a url", "https://user:pw@founderizer.com",
                    "https://founderizer.com?x=1"] {
            #expect(throws: ProblemReportError.self) { try ProblemReportClient.endpoint(channel: bad) }
        }
    }

    /// The hub names the channel, so a hub must not be able to send the customer's words to another site: plain HTTP
    /// and every host outside our own domain are refused (review of 14 November 2026).
    @Test func aChannelWithoutHTTPSOrOutsideOurDomainIsRefused() throws {
        for bad in ["http://founderizer.com", "http://staging.founderizer.com", "https://example.com",
                    "https://founderizer.com.example.net", "https://xfounderizer.com"] {
            #expect(throws: ProblemReportError.self) { try ProblemReportClient.endpoint(channel: bad) }
        }
        _ = try ProblemReportClient.endpoint(channel: "HTTPS://Staging.Founderizer.com")
    }

    /// A redirect is an answer, never a second request: a site that redirects the report gets nothing more, and the
    /// other site never sees it (review of 14 November 2026).
    @Test func aRedirectIsRefusedAndTheOtherSiteSeesNothing() async throws {
        let client = ProblemReportClient(protocolClasses: [RedirectingSite.self])
        await #expect(throws: ProblemReportError.self) {
            _ = try await client.send(report(), channel: nil, fleet: nil)
        }
        let asked = RedirectingSite.asked()
        #expect(asked.contains("https://founderizer.com/api/report"))
        #expect(!asked.contains { $0.hasPrefix("https://example.com") })
    }

    /// E2 (the owner's yes of 14 November 2026 to its picture): a key in what he typed waits for him to take it out.
    @Test func aTextThatHoldsAKeyIsNotSentAndSaysWhy() {
        let keyed = report(text: "It broke after I pasted sk-ant-api03-EXAMPLEEXAMPLEEXAMPLEEXAMPLE into the chat.")
        #expect(keyed.holdsKey)
        #expect(!keyed.isReady)
        #expect(keyed.refusal == "This text holds what looks like a key. Take it out, then send.")
        #expect(keyed.lines.contains("It broke after"))            // Copy report still has his words
        #expect(!report().holdsKey && report().isReady)
    }

    @Test func onlyAReferenceWeCanQuoteBackIsAReceipt() {
        #expect(ProblemReceipt(reference: "FR-1042").isValid)
        #expect(!ProblemReceipt(reference: "").isValid)
        #expect(!ProblemReceipt(reference: String(repeating: "x", count: 41)).isValid)
    }
}

/// A site that redirects every report to another site, which would take it and give a receipt. It remembers each
/// address that it was asked, so a test sees whether the client followed the redirect.
final class RedirectingSite: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var addresses: [String] = []
    private static let lock = NSLock()

    static func asked() -> [String] { lock.lock(); defer { lock.unlock() }; return addresses }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.addresses.append(url.absoluteString); Self.lock.unlock()
        if url.host == "example.com" {
            let taken = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: taken, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"reference":"FR-1"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let away = URL(string: "https://example.com/collect")!
        let moved = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                    headerFields: ["Location": away.absoluteString])!
        var next = request
        next.url = away
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
        // A client that refuses the redirect reads the 307 itself.
        client?.urlProtocol(self, didReceive: moved, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
