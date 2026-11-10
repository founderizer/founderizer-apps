import Foundation
import Testing
@testable import FleetCore

// What the hub says when it refuses a read, and which of its refusals another send can settle.
//
// The reads behind Health, Machines, Team, Servers, Checks, Capacity, Triggers, Events, Artifacts and Desktop all go
// through one path, and that path used to map every status it did not know to a bare number. The hub writes a line
// for the owner beside each of them, so these are the tests that the line arrives.

@Test func aRefusedReadCarriesTheHubsOwnSentence() async throws {
    let refusal = try OneAnswer(status: "403 Forbidden") { _ in #"{"error":"this Mac is not the owner's machine"}"# }
    let hub = URL(string: "http://127.0.0.1:\(refusal.port)")!
    do {
        _ = try await HubClient().health(hub: hub, database: "db")
        Issue.record("The stand-in answered 403, so the read cannot succeed.")
    } catch let HubError.refusal(status, words) {
        #expect(status == 403)
        #expect(words == "this Mac is not the owner's machine")
        #expect(HubError.said(HubError.refusal(status, words)) == "this Mac is not the owner's machine")
    }
    #expect(refusal.received.starts(with: Data("GET /ui/health?db=db HTTP/1.1\r\n".utf8)))
}

@Test func aRefusalWithNoWordsKeepsItsStatusAndSaysNothingOfItsOwn() async throws {
    let refusal = try OneAnswer(status: "503 Service Unavailable") { _ in "" }
    do {
        _ = try await HubClient().machines(hub: URL(string: "http://127.0.0.1:\(refusal.port)")!, database: "db")
        Issue.record("The stand-in answered 503, so the read cannot succeed.")
    } catch let HubError.refusal(status, words) {
        #expect(status == 503 && words == HubError.unexplained)
        // Nothing of the hub's to show, so the screen keeps its own line instead of printing a number.
        #expect(HubError.said(HubError.refusal(status, words)) == nil)
    }
}

@Test func theTwoRefusalsTheCheckedOutputsActOnKeepTheirMeaning() throws {
    let body = Data(#"{"error":"hub generation changed; refresh state"}"#.utf8)
    #expect(HubClient.readRefusal(status: 409, body: body, checkedOutputs: true) as? ArtifactError == .stale)
    #expect(HubClient.readRefusal(status: 422, body: body, checkedOutputs: true) as? ArtifactError == .refusedText)
    guard case let HubError.refusal(status, words) = HubClient.readRefusal(status: 500, body: body, checkedOutputs: true) else {
        Issue.record("A status the outputs do not act on carries the hub's words."); return
    }
    #expect(status == 500 && words == "hub generation changed; refresh state")
}

// Only the checked outputs act on 409 and 422. Every other read is a screen that cannot reload an output list, and
// "The checked output list changed. Reload checked outputs." was the sentence all eight of them showed for a 409.
@Test func a409OnEveryOtherReadCarriesTheHubsOwnSentence() throws {
    let body = Data(#"{"error":"hub generation changed; refresh state"}"#.utf8)
    for status in [409, 422] {
        guard case let HubError.refusal(code, words) = HubClient.readRefusal(status: status, body: body, checkedOutputs: false) else {
            Issue.record("A \(status) outside the checked outputs carries the hub's words, not the outputs' sentence."); return
        }
        #expect(code == status && words == "hub generation changed; refresh state")
    }
    // And with no words of its own it is still its own status, never the outputs' sentence.
    guard case let HubError.refusal(code, words) = HubClient.readRefusal(status: 409, body: Data(), checkedOutputs: false) else {
        Issue.record("A 409 with an empty body is a refusal with its status."); return
    }
    #expect(code == 409 && words == HubError.unexplained)
}

@Test func theGenerationChangedReachesTheScreenThatReadTheTriggers() async throws {
    let refusal = try OneAnswer(status: "409 Conflict") { _ in #"{"error":"hub generation changed; refresh state"}"# }
    let hub = URL(string: "http://127.0.0.1:\(refusal.port)")!
    do {
        _ = try await HubClient().triggers(hub: hub, database: "db")
        Issue.record("The stand-in answered 409, so the read cannot succeed.")
    } catch {
        #expect(error as? ArtifactError == nil)
        #expect(HubError.said(error) == "hub generation changed; refresh state")
    }
}

@Test func theWordsOfARefusalAreBoundedAndNeverEmpty() throws {
    #expect(HubClient.words(in: Data()) == HubError.unexplained)
    #expect(HubClient.words(in: Data("not json".utf8)) == HubError.unexplained)
    #expect(HubClient.words(in: Data(#"{"error":"   "}"#.utf8)) == HubError.unexplained)
    let long = String(repeating: "a", count: 900)
    #expect(HubClient.words(in: Data(#"{"error":"\#(long)"}"#.utf8)).count == 500)
}

@Test func onlyTheFinalRefusalsAreFinalAndA409IsItsOwnQuestion() {
    for status in [400, 403, 404, 413, 415, 422, 503] {
        #expect(HubError.refusal(status, "no").definitiveRefusal)
        #expect(!HubError.refusal(status, "no").conflict)
    }
    // A 409 is a refusal, but the hub also answers it to a write whose base simply moved, so it is not final.
    #expect(!HubError.refusal(409, "the profile changed meanwhile; reload it").definitiveRefusal)
    #expect(HubError.refusal(409, "the profile changed meanwhile; reload it").conflict)
    #expect(!HubError.refusal(500, "server error").definitiveRefusal)
    #expect(!HubError.refusal(500, "server error").conflict)
    #expect(!HubError.invalidResponse.definitiveRefusal && !HubError.invalidResponse.conflict)
    #expect(HubError.said(HubError.unavailable) == nil)
}
