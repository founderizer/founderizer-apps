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
    } catch let HubError.refusal(refused) {
        #expect(refused.status == 403)
        #expect(refused.hubWords == "this Mac is not the owner's machine")
        #expect(HubError.said(HubError.refusal(refused)) == "this Mac is not the owner's machine")
    }
    #expect(refusal.received.starts(with: Data("GET /ui/health?db=db HTTP/1.1\r\n".utf8)))
}

@Test func aRefusalWithNoWordsKeepsItsStatusAndSaysNothingOfItsOwn() async throws {
    let refusal = try OneAnswer(status: "503 Service Unavailable") { _ in "" }
    do {
        _ = try await HubClient().machines(hub: URL(string: "http://127.0.0.1:\(refusal.port)")!, database: "db")
        Issue.record("The stand-in answered 503, so the read cannot succeed.")
    } catch let HubError.refusal(refused) {
        #expect(refused.status == 503 && refused.hubWords == HubError.unexplained)
        // Nothing of the hub's to show, so the screen keeps its own line instead of printing a number.
        #expect(HubError.said(HubError.refusal(refused)) == nil)
    }
}

@Test func theTwoRefusalsTheCheckedOutputsActOnKeepTheirMeaning() throws {
    let body = Data(#"{"error":"hub generation changed; refresh state"}"#.utf8)
    #expect(HubClient.readRefusal(status: 409, body: body, checkedOutputs: true) as? ArtifactError == .stale)
    #expect(HubClient.readRefusal(status: 422, body: body, checkedOutputs: true) as? ArtifactError == .refusedText)
    guard case let HubError.refusal(refused) = HubClient.readRefusal(status: 500, body: body, checkedOutputs: true) else {
        Issue.record("A status the outputs do not act on carries the hub's words."); return
    }
    #expect(refused.status == 500 && refused.hubWords == "hub generation changed; refresh state")
}

// Only the checked outputs act on 409 and 422. Every other read is a screen that cannot reload an output list, and
// "The checked output list changed. Reload checked outputs." was the sentence all eight of them showed for a 409.
@Test func a409OnEveryOtherReadCarriesTheHubsOwnSentence() throws {
    let body = Data(#"{"error":"hub generation changed; refresh state"}"#.utf8)
    for status in [409, 422] {
        guard case let HubError.refusal(refused) = HubClient.readRefusal(status: status, body: body, checkedOutputs: false) else {
            Issue.record("A \(status) outside the checked outputs carries the hub's words, not the outputs' sentence."); return
        }
        #expect(refused.status == status && refused.hubWords == "hub generation changed; refresh state")
    }
    // And with no words of its own it is still its own status, never the outputs' sentence.
    guard case let HubError.refusal(refused) = HubClient.readRefusal(status: 409, body: Data(), checkedOutputs: false) else {
        Issue.record("A 409 with an empty body is a refusal with its status."); return
    }
    #expect(refused.status == 409 && refused.hubWords == HubError.unexplained)
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
    #expect(HubRefusal.read(status: 400, body: Data()).hubWords == HubError.unexplained)
    #expect(HubRefusal.read(status: 400, body: Data("not json".utf8)).hubWords == HubError.unexplained)
    #expect(HubRefusal.read(status: 400, body: Data(#"{"error":"   "}"#.utf8)).hubWords == HubError.unexplained)
    let long = String(repeating: "a", count: 900)
    #expect(HubRefusal.read(status: 400, body: Data(#"{"error":"\#(long)"}"#.utf8)).hubWords.count == 500)
}

@Test func onlyTheFinalRefusalsAreFinalAndA409IsItsOwnQuestion() {
    for status in [400, 403, 404, 413, 415, 422, 503] {
        #expect(HubError.refusal(HubRefusal(status: status, hubWords: "no")).definitiveRefusal)
        #expect(!HubError.refusal(HubRefusal(status: status, hubWords: "no")).conflict)
    }
    // A 409 is a refusal, but the hub also answers it to a write whose base simply moved, so it is not final.
    #expect(!HubError.refusal(HubRefusal(status: 409, hubWords: "the profile changed meanwhile; reload it")).definitiveRefusal)
    #expect(HubError.refusal(HubRefusal(status: 409, hubWords: "the profile changed meanwhile; reload it")).conflict)
    #expect(!HubError.refusal(HubRefusal(status: 500, hubWords: "server error")).definitiveRefusal)
    #expect(!HubError.refusal(HubRefusal(status: 500, hubWords: "server error")).conflict)
    #expect(!HubError.invalidResponse.definitiveRefusal && !HubError.invalidResponse.conflict)
    #expect(HubError.said(HubError.unavailable) == nil)
}
