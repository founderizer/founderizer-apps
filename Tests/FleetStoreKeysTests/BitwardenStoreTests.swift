import Foundation
import Testing
@testable import FleetStoreKeys

/// **The client of the store against a stand-in of Bitwarden's two hosts** (`StoreWire`).
struct BitwardenStoreTests {
    private let secrets = "/organizations/\(Invented.organization)/secrets"

    /// The create's outcome decides between a second create and the find path. The bug: "Nothing was sent" for a
    /// call that arrived, so a Try again makes a second item; or a timeout of the sign-in taken for an unknown create.
    @Test func theCreateSaysNotSentOnlyWhenNothingLeftAndUnknownForAllThatMayHaveArrived() async {
        let cases: [(StoreWire.Reply, StoreCreate)] = [
            (.answer(200, "{\"id\":\"\(Invented.item)\"}", [:]), .made(Invented.item)),
            (.answer(200, "{\"id\":\"\(Invented.item.uppercased())\"}", [:]), .unknown),
            (.answer(200, "not json", [:]), .unknown),
            (.answer(500, "{}", [:]), .unknown),
            (.redirect("/elsewhere"), .unknown),
            (.answer(400, "{}", [:]), .refused),
            (.answer(404, "{}", [:]), .refused),
            (.fail(.cannotConnectToHost), .notSent),
            (.fail(.notConnectedToInternet), .notSent),
            (.fail(.timedOut), .unknown),
            (.fail(.networkConnectionLost), .unknown),
        ]
        for (reply, outcome) in cases {
            let wire = StoreWire()
            wire.signsIn()
            wire.on("POST", secrets, reply)
            let made = await wire.store().create(name: "shop/stripe-key-a1b2c3", value: "sk_test_invented", note: "mark",
                                                 project: Invented.project)
            #expect(made == outcome, "\(reply)")
            #expect(wire.calls("POST", secrets).count == 1, "\(reply)")
        }
        // A sign-in that times out sends no create: the create was not sent.
        let wire = StoreWire()
        wire.on("POST", "/connect/token", .fail(.timedOut))
        #expect(await wire.store().create(name: "a/b", value: "v", note: "n", project: Invented.project) == .notSent)
        #expect(wire.calls("POST", secrets).isEmpty)
    }

    /// The bug: the token follows a redirect to another host, or a session keeps a cookie or an answer between calls.
    /// A `URLProtocol` stand-in does not use the cookie store or the cache of a session, so the test reads the
    /// store's own session too: a default or shared session passes the calls below.
    @Test func aRedirectEndsTheCallAndTheSessionKeepsNoCookieAndNoAnswer() async {
        let wire = StoreWire()
        wire.on("POST", "/connect/token", 200, Invented.signIn(), headers: ["Set-Cookie": "seen=1; Path=/; Secure"])
        let project = "/projects/\(Invented.project)"
        wire.on("GET", project, 200, "{\"id\":\"\(Invented.project)\",\"read\":true,\"write\":true}",
                headers: ["Cache-Control": "max-age=3600", "Set-Cookie": "kept=2; Path=/; Secure"])
        let store = wire.store()
        #expect(await store.canWrite(project: Invented.project) == .writes)
        #expect(await store.canWrite(project: Invented.project) == .writes)
        #expect(wire.calls("GET", project).count == 2)
        #expect(wire.calls.allSatisfy { $0.headers.keys.allSatisfy { $0.lowercased() != "cookie" } })
        wire.on("GET", "/secrets/\(Invented.item)", .redirect("/elsewhere"))
        #expect(await store.read(id: Invented.item) == .failed(.noAnswer))
        #expect(wire.calls.allSatisfy { $0.path != "/elsewhere" })
        let session = store.sessionConfiguration
        #expect(session.httpCookieStorage == nil && !session.httpShouldSetCookies && session.httpCookieAcceptPolicy == .never)
        #expect(session.urlCache == nil && session.urlCredentialStorage == nil)
        // Bitwarden's own pair only: a region that is not us or eu makes no store.
        #expect(BitwardenStore(token: Invented.token, region: "self-hosted", organization: Invented.organization) == nil)
        #expect(BitwardenStore(token: Invented.token, region: "US", organization: Invented.organization) == nil)
        #expect(BitwardenStore(token: Invented.token, region: "eu", organization: Invented.organization) != nil)
        #expect(BitwardenStore(token: Invented.token, region: "us", organization: Invented.organization.uppercased()) == nil)
    }

    /// The sign-in as the SDK sends it, and its definite refusals. The bug: a wrong scope or grant that Bitwarden
    /// refuses, a network fault taken for a refused token, or a token of another organization that writes there.
    @Test func theSignInSendsTheSDKsFormAndRefusesOnlyForSure() async {
        let wire = StoreWire()
        wire.signsIn()
        #expect(await wire.store().signIn() == .ok)
        let form = wire.calls("POST", "/connect/token")[0].form
        #expect(form == ["scope": "api.secrets", "grant_type": "client_credentials", "client_id": Invented.tokenID,
                         "client_secret": "inventedClientSecret0123456789"])
        let cases: [(StoreWire.Reply, StoreSignIn)] = [
            (.answer(400, "{\"error\":\"invalid_client\"}", [:]), .failed(.tokenRefused)),
            (.answer(400, "{\"error\":\"invalid_scope\"}", [:]), .failed(.refused(400))),
            (.answer(500, "{\"error\":\"invalid_client\"}", [:]), .failed(.noAnswer)),
            (.answer(200, Invented.signIn(organization: Invented.otherOrganization), [:]), .failed(.otherOrganization)),
            (.fail(.timedOut), .failed(.noAnswer)),
            (.fail(.cannotFindHost), .failed(.notSent)),
        ]
        for (reply, outcome) in cases {
            let wire = StoreWire()
            wire.on("POST", "/connect/token", reply)
            #expect(await wire.store().signIn() == outcome, "\(reply)")
        }
        // A payload that the token's key does not open: a token whose key part is wrong.
        let other = StoreWire()
        other.signsIn()
        let wrongKey = "0.\(Invented.tokenID).inventedClientSecret0123456789:\(Data(repeating: 1, count: 16).base64EncodedString())"
        #expect(await other.store(token: wrongKey).signIn() == .failed(.tokenUnusable))
    }

    /// The bug: a 401 of an old bearer counted as a refused token (a card that asks for a new key after an hour), or
    /// a 401 of a fresh one sent again and again.
    @Test func a401CountsOnlyDirectlyAfterAFreshSignIn() async {
        let project = "/projects/\(Invented.project)"
        let writes = "{\"id\":\"\(Invented.project)\",\"read\":true,\"write\":true}"
        let wire = StoreWire()
        wire.signsIn()
        wire.on("GET", project, 200, writes)
        wire.on("GET", project, 401)
        wire.on("GET", project, 200, writes)
        let store = wire.store()
        #expect(await store.canWrite(project: Invented.project) == .writes)
        #expect(await store.canWrite(project: Invented.project) == .writes)     // the 401, a new sign-in, once more
        #expect(wire.calls("POST", "/connect/token").count == 2)
        #expect(wire.calls("GET", project).count == 3)

        let fresh = StoreWire()
        fresh.signsIn()
        fresh.on("GET", project, 401)
        #expect(await fresh.store().canWrite(project: Invented.project) == .failed(.tokenRefused))
        #expect(fresh.calls("GET", project).count == 1)
    }

    /// The bug: an update takes the mark or the project away, so the find path and the operator lose the item.
    @Test func anUpdateSendsTheNameTheNoteAndTheProjectAgain() async throws {
        let wire = StoreWire()
        wire.signsIn()
        wire.on("PUT", "/secrets/\(Invented.item)", 200, "{\"id\":\"\(Invented.item)\"}")
        let own = OwnStoreItem(id: Invented.item, project: Invented.project, name: "shop/stripe-key-a1b2c3", note: "the mark")
        #expect(await wire.store().update(own, value: "sk_test_new") == .updated)
        let body = try #require(wire.calls("PUT", "/secrets/\(Invented.item)").first?.json)
        #expect(EncString.openText(body["key"] as? String ?? "", key: Invented.key) == "shop/stripe-key-a1b2c3")
        #expect(EncString.openText(body["note"] as? String ?? "", key: Invented.key) == "the mark")
        #expect(EncString.openText(body["value"] as? String ?? "", key: Invented.key) == "sk_test_new")
        #expect(body["projectIds"] as? [String] == [Invented.project])
        // An id that is no STORE_UUID reaches no path.
        let bad = OwnStoreItem(id: "../projects", project: Invented.project, name: "n", note: "m")
        #expect(await wire.store().update(bad, value: "v") == .failed(.notSent))
        #expect(await wire.store().read(id: Invented.item.uppercased()) == .failed(.notSent))
        #expect(wire.calls("PUT", "/secrets/\(Invented.item)").count == 1)
    }

    /// The find path: only the items of that name whose read gives the mark and the project. The bug: an item that a
    /// list answer names, or one of another project, taken as this Mac's own.
    @Test func findGivesOnlyTheReadItemsWithTheMarkInTheProject() async {
        let wire = StoreWire()
        wire.signsIn()
        let second = "22345678-9abc-4def-8123-456789abcdef"
        let third = "32345678-9abc-4def-8123-456789abcdef"
        let list: [String: Any] = ["secrets": [
            ["id": Invented.item, "key": try! EncString.seal("shop/k-a1b2c3", key: Invented.key)],
            ["id": second, "key": try! EncString.seal("shop/k-a1b2c3", key: Invented.key)],
            ["id": third, "key": try! EncString.seal("other/name", key: Invented.key)],
        ]]
        wire.on("GET", "/projects/\(Invented.project)/secrets", 200,
                String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self))
        wire.on("GET", "/secrets/\(Invented.item)", 200, Invented.secret(name: "shop/k-a1b2c3", note: "mark"))
        wire.on("GET", "/secrets/\(second)", 200, Invented.secret(id: second, name: "shop/k-a1b2c3", note: "another mark"))
        let found = await wire.store().find(name: "shop/k-a1b2c3", note: "mark", project: Invented.project)
        #expect(found == .items([StoreItem(id: Invented.item, project: Invented.project, name: "shop/k-a1b2c3", note: "mark")]))
        #expect(wire.calls("GET", "/secrets/\(third)").isEmpty)
    }
}
