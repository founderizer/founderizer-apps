import Foundation
import Testing
@testable import FleetCore

/// The owner's own private network (Tailscale): the one credential they paste, the tag this app puts in their
/// policy file, and the key it mints for each machine. Every request is proved against a stand-in for Tailscale,
/// so none of this needs a network or an account.
struct PrivateNetworkTests {

    // MARK: - Tailscale, stood in for

    /// Tailscale as this app talks to it: it records every request, and answers the ones it is given answers for.
    private final class StandIn: @unchecked Sendable {
        struct Call: Sendable {
            let method: String
            let url: String
            let headers: [String: String]
            let body: String
        }
        private let lock = NSLock()
        private var made: [Call] = []
        /// What to answer, by the path of the request.
        var answers: [String: (Int, String, [String: String])] = [:]

        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return made }
        var paths: [String] { calls.map { URL(string: $0.url)?.path ?? "" } }
        func call(_ path: String) -> Call? { calls.first { URL(string: $0.url)?.path == path } }
        func count(_ path: String) -> Int { calls.filter { URL(string: $0.url)?.path == path }.count }

        private func record(_ call: Call) { lock.lock(); made.append(call); lock.unlock() }

        var exchange: NetworkClient.Exchange {
            { [self] request in
                let url = request.url!
                record(Call(method: request.httpMethod ?? "GET", url: url.absoluteString,
                            headers: request.allHTTPHeaderFields ?? [:],
                            body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
                let (status, body, headers) = answers[url.path] ?? (404, "{\"message\":\"no such thing\"}", [:])
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                               headerFields: headers)!
                return (Data(body.utf8), response)
            }
        }

        /// A tailnet that answers everything: a token, a policy file, its users and a key.
        static func working(policy: String, etag: String? = "\"abc\"", users: String? = nil) -> StandIn {
            let one = StandIn()
            one.answers["/api/v2/oauth/token"] =
                (200, "{\"access_token\":\"tskey-api-let-me-in\",\"token_type\":\"Bearer\",\"expires_in\":3600}", [:])
            one.answers["/api/v2/tailnet/-/acl"] = (200, policy, etag.map { ["ETag": $0] } ?? [:])
            one.answers["/api/v2/tailnet/-/keys"] =
                (200, "{\"id\":\"k1\",\"key\":\"tskey-auth-k1-abcdef\",\"expires\":\"2026-10-19T00:00:00Z\"}", [:])
            if let users { one.answers["/api/v2/tailnet/-/users"] = (200, users, [:]) }
            return one
        }
    }

    private static let credential = NetworkCredential(clientID: "kAbCd1234CNTRL",
                                                      secret: "tskey-client-kAbCd1234CNTRL-secretpart")

    // MARK: - The credential the owner pastes

    @Test func aCredentialIsReadTheWayTailscaleMakesOne() throws {
        #expect(Self.credential.isValid)
        #expect(NetworkCredential().problem == "Paste the client id from Tailscale.")
        #expect(NetworkCredential(clientID: "has space", secret: "tskey-client-x").problem?
            .contains("letters and digits") == true)
        #expect(NetworkCredential(clientID: "kAbCd1234", secret: "").problem == "Paste the client secret from Tailscale.")
        // An auth key is not a credential: pasting the wrong one of Tailscale's two things is the likely mistake.
        #expect(NetworkCredential(clientID: "kAbCd1234", secret: "tskey-auth-kAbCd-xyz").problem?
            .contains("tskey-client-") == true)
    }

    @Test func aCredentialGoesToTheKeychainAndComesBack() throws {
        let kept = try Self.credential.stored()
        let read = NetworkCredential(stored: kept)
        #expect(read == Self.credential)
        // Nothing but those two values, so no encoder can carry anything else along.
        #expect(String(decoding: kept, as: UTF8.self) == "kAbCd1234CNTRL\ntskey-client-kAbCd1234CNTRL-secretpart")
        #expect(NetworkCredential(stored: Data("one line only".utf8)) == nil)
        #expect(NetworkCredential(stored: Data("id\nnot-a-secret".utf8)) == nil)
        #expect(throws: NetworkError.notACredential) { try NetworkCredential().stored() }
    }

    @Test func theIdIsShownAndTheSecretIsNot() {
        #expect(Self.credential.shownID == "kAbCd1234CNTRL")
        #expect(!Self.credential.shownID.contains("secretpart"))
    }

    // MARK: - The policy file, read and written as the HuJSON it is

    private static let withTagOwners = """
    // The owner's own rules. This comment must still be here afterwards.
    {
      "tagOwners": {
        "tag:server": ["me@example.com"],
      },
      "acls": [
        {"action": "accept", "src": ["*"], "dst": ["*:*"]},
      ],
    }
    """

    private static let withoutTagOwners = """
    {
      // Nothing is tagged here yet.
      "acls": [
        {"action": "accept", "src": ["*"], "dst": ["*:*"]},
      ],
    }
    """

    @Test func aTagIsFoundOnlyWhereItIsActuallyDefined() {
        #expect(PolicyFile.defines("tag:server", in: Self.withTagOwners))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: Self.withTagOwners))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: Self.withoutTagOwners))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: ""))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: "{}"))
        // Tailscale reads tags in lower case, and so does this.
        #expect(PolicyFile.defines("tag:server", in: """
        {"tagOwners": {"TAG:Server": []}}
        """))
    }

    @Test func aTagOwnersInACommentOrAValueIsNotTheKey() {
        // The whole reason the file is read as text: none of these defines anything.
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: """
        {
          // "tagOwners": {"tag:founderizer": []},
          "acls": [],
        }
        """))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: """
        {
          /* "tagOwners": { "tag:founderizer": [] } */
          "acls": [],
        }
        """))
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: """
        {"ssh": [{"action": "check", "comment": "tagOwners tag:founderizer"}]}
        """))
        // A tag used in a rule is not a tag that exists.
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: """
        {"acls": [{"action": "accept", "src": ["tag:founderizer"], "dst": ["*:*"]}]}
        """))
        // A tag of a nested object is not a tag of `tagOwners`.
        #expect(!PolicyFile.defines(PrivateNetwork.tag, in: """
        {"tagOwners": {"tag:server": []}, "grants": [{"app": {"tag:founderizer": []}}]}
        """))
    }

    @Test func theTagIsAddedAndNothingElseChanges() throws {
        let written = try #require(PolicyFile.adding(PrivateNetwork.tag, owner: "me@example.com",
                                                     to: Self.withTagOwners))
        #expect(PolicyFile.defines(PrivateNetwork.tag, in: written))
        #expect(written.contains("\"\(PrivateNetwork.tag)\": [\"me@example.com\"],"))
        // Every line of the owner's own file is still there, comment and all: taking the one inserted line out
        // again gives back exactly what Tailscale gave us.
        let inserted = "\n\t\t\"\(PrivateNetwork.tag)\": [\"me@example.com\"],"
        #expect(written.replacingOccurrences(of: inserted, with: "") == Self.withTagOwners)
        #expect(written.contains("This comment must still be here afterwards"))
        #expect(written.contains("\"tag:server\": [\"me@example.com\"],"))
    }

    @Test func aFileWithNoTagOwnersGetsOne() throws {
        let written = try #require(PolicyFile.adding(PrivateNetwork.tag, owner: nil, to: Self.withoutTagOwners))
        #expect(PolicyFile.defines(PrivateNetwork.tag, in: written))
        #expect(written.contains("\"tagOwners\": {"))
        // A tag nobody owns belongs to the tailnet's own admins, which is enough for the credential that made it.
        #expect(written.contains("\"\(PrivateNetwork.tag)\": [],"))
        #expect(written.contains("Nothing is tagged here yet"))
        #expect(PolicyFile.defines("tag:server", in: """
        {"tagOwners": {"tag:server": []}}
        """))
        // An empty network, which is what a new tailnet is.
        let bare = try #require(PolicyFile.adding(PrivateNetwork.tag, owner: nil, to: "{}"))
        #expect(PolicyFile.defines(PrivateNetwork.tag, in: bare))
    }

    @Test func thisAppWillNotGuessAtAFileItCannotRead() {
        #expect(PolicyFile.adding(PrivateNetwork.tag, owner: nil, to: "") == nil)
        #expect(PolicyFile.adding(PrivateNetwork.tag, owner: nil, to: "// only a comment") == nil)
        // Not a tag, so not written.
        #expect(PolicyFile.adding("founderizer", owner: nil, to: "{}") == nil)
        #expect(PolicyFile.adding("tag:Founderizer", owner: nil, to: "{}") == nil)
    }

    @Test func onlyAPlainAddressGoesIntoTheOwnersOwnFile() throws {
        for bad in ["not an address", "me@example", "\" , \"tag:x\": [\"a\"], \"b\": \"", "me@example.com\nx"] {
            let written = try #require(PolicyFile.adding(PrivateNetwork.tag, owner: bad, to: "{}"))
            #expect(written.contains("\"\(PrivateNetwork.tag)\": [],"), "owner \(bad) must be left out")
            #expect(!written.contains(bad))
        }
        #expect(PolicyFile.isOwnerName("me@example.com"))
        #expect(!PolicyFile.isOwnerName("me@example"))
    }

    // MARK: - The token

    @Test func theTokenIsAskedForWithTheClientCredentialsGrant() async throws {
        let tailscale = StandIn.working(policy: "{}")
        let token = try await NetworkClient(exchange: tailscale.exchange).token(Self.credential)
        #expect(token == "tskey-api-let-me-in")
        let call = try #require(tailscale.call("/api/v2/oauth/token"))
        #expect(call.method == "POST")
        #expect(call.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(call.body.contains("grant_type=client_credentials"))
        #expect(call.body.contains("client_id=kAbCd1234CNTRL"))
        #expect(call.body.contains("client_secret=tskey-client-kAbCd1234CNTRL-secretpart"))
        // The secret is in the body and never in the address.
        #expect(!call.url.contains("secretpart"))
    }

    @Test func aCredentialTailscaleRefusesIsSaidPlainly() async throws {
        let tailscale = StandIn()
        tailscale.answers["/api/v2/oauth/token"] = (401, "{\"message\":\"invalid client\"}", [:])
        await #expect(throws: NetworkError.notAccepted) {
            try await NetworkClient(exchange: tailscale.exchange).token(Self.credential)
        }
        // A credential of the wrong shape never reaches Tailscale at all.
        let unused = StandIn()
        await #expect(throws: NetworkError.notACredential) {
            try await NetworkClient(exchange: unused.exchange).token(NetworkCredential())
        }
        #expect(unused.calls.isEmpty)
    }

    // MARK: - The key for one machine

    @Test func oneKeyForOneMachine() async throws {
        let tailscale = StandIn.working(policy: "{}")
        let key = try await NetworkClient(exchange: tailscale.exchange).key(for: "hub", with: Self.credential)
        #expect(key == "tskey-auth-k1-abcdef")
        let call = try #require(tailscale.call("/api/v2/tailnet/-/keys"))
        #expect(call.method == "POST")
        #expect(call.headers["Authorization"] == "Bearer tskey-api-let-me-in")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        let create = try #require(((body["capabilities"] as? [String: Any])?["devices"]
            as? [String: Any])?["create"] as? [String: Any])
        // Used once, for one machine, and never ephemeral: ephemeral minutes are metered on the free plan.
        #expect(create["reusable"] as? Bool == false)
        #expect(create["ephemeral"] as? Bool == false)
        #expect(create["preauthorized"] as? Bool == true)
        #expect(create["tags"] as? [String] == [PrivateNetwork.tag])
        #expect(body["expirySeconds"] as? Int == 900)
        #expect(body["description"] as? String == "Founderizer: hub")
    }

    /// A server that joins a fleet gets the tags of the hub's join line from a key too, as from the sign-in link, so the
    /// tailnet's policy knows it by the same tags; a tag this app would not write itself is never sent.
    @Test func aKeyCarriesTheTagsOfTheJoinLine() async throws {
        let tags = NetworkSignIn.tags(inLine: "tailscale status >/dev/null 2>&1 || tailscale up "
                                      + "--advertise-tags=tag:claude-code-dev,tag:terminal-relay-worker --accept-dns=false; "
                                      + "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=x sh")
        #expect(tags == ["tag:claude-code-dev", "tag:terminal-relay-worker"])
        for (given, sent) in [(tags, tags), (["tag:Bad Tag"], [PrivateNetwork.tag]), ([], [PrivateNetwork.tag])] {
            let tailscale = StandIn.working(policy: "{}")
            _ = try await NetworkClient(exchange: tailscale.exchange).key(for: "worker-9", with: Self.credential,
                                                                         tags: given)
            let call = try #require(tailscale.call("/api/v2/tailnet/-/keys"))
            let body = try #require(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
            let create = try #require(((body["capabilities"] as? [String: Any])?["devices"]
                as? [String: Any])?["create"] as? [String: Any])
            #expect(create["tags"] as? [String] == sent)
        }
    }

    @Test func aMachinesNameIsFitForTailscalesOwnScreen() {
        #expect(NetworkClient.description(for: "studio") == "Founderizer: studio")
        #expect(NetworkClient.description(for: "") == "Founderizer: a machine")
        // Nothing of a name reaches Tailscale that this app would not write itself.
        #expect(NetworkClient.description(for: "a b\"c;d") == "Founderizer: abcd")
        #expect(NetworkClient.description(for: String(repeating: "m", count: 200)).count == 50)
    }

    @Test func anAnswerThatIsNotAKeyIsNotPassedOn() async throws {
        let tailscale = StandIn.working(policy: "{}")
        tailscale.answers["/api/v2/tailnet/-/keys"] = (200, "{\"id\":\"k1\",\"key\":\"not a key\"}", [:])
        await #expect(throws: NetworkError.notUnderstood) {
            try await NetworkClient(exchange: tailscale.exchange).key(for: "hub", with: Self.credential)
        }
        #expect(NetworkClient.isKey("tskey-auth-k1-abc"))
        #expect(!NetworkClient.isKey("tskey auth with a space"))
        #expect(!NetworkClient.isKey("notatskey-auth"))
    }

    @Test func tailscalesOwnWordsAreWhatARefusalSays() async throws {
        let tailscale = StandIn.working(policy: "{}")
        tailscale.answers["/api/v2/tailnet/-/keys"] =
            (400, "{\"message\":\"requested tags are invalid or not permitted\"}", [:])
        let failed = await #expect(throws: NetworkError.self) {
            try await NetworkClient(exchange: tailscale.exchange).key(for: "hub", with: Self.credential)
        }
        #expect(failed == .refused("requested tags are invalid or not permitted"))
        #expect(failed?.errorDescription?.contains("Tailscale refused") == true)
    }

    // MARK: - Getting the network ready, once

    @Test func theTagIsWrittenOnceAndTheFileKeepsItsOwnLines() async throws {
        let tailscale = StandIn.working(policy: Self.withTagOwners, etag: "\"v1\"",
                                        users: "{\"users\":[{\"loginName\":\"me@example.com\",\"role\":\"owner\"}]}")
        let wrote = try await NetworkClient(exchange: tailscale.exchange).prepare(Self.credential)
        #expect(wrote)
        let posted = try #require(tailscale.calls.last { URL(string: $0.url)?.path == "/api/v2/tailnet/-/acl"
            && $0.method == "POST" })
        #expect(posted.headers["Content-Type"] == "application/hujson")
        // Against what was read, so a change somebody else made meanwhile is not overwritten.
        #expect(posted.headers["If-Match"] == "\"v1\"")
        #expect(PolicyFile.defines(PrivateNetwork.tag, in: posted.body))
        #expect(posted.body.contains("This comment must still be here afterwards"))
        #expect(posted.body.contains("\"tag:server\": [\"me@example.com\"],"))
        // The tailnet's own owner owns the tag, which is the most ordinary thing to write in that file.
        #expect(posted.body.contains("\"\(PrivateNetwork.tag)\": [\"me@example.com\"],"))
    }

    @Test func aNetworkThatIsReadyIsNotWrittenTo() async throws {
        let ready = """
        {"tagOwners": {"\(PrivateNetwork.tag)": []}}
        """
        let tailscale = StandIn.working(policy: ready)
        let wrote = try await NetworkClient(exchange: tailscale.exchange).prepare(Self.credential)
        #expect(!wrote)
        #expect(!tailscale.calls.contains { $0.method == "POST" && $0.url.contains("/acl") })
        let standing = try await NetworkClient(exchange: tailscale.exchange).standing(Self.credential)
        #expect(standing.accepted && standing.tagReady)
    }

    @Test func aCredentialEndedInTailscaleIsAnAnswerAndNotAFailure() async throws {
        // What a revoked credential looks like: the screen says so, instead of finding out at the next install.
        let tailscale = StandIn()
        tailscale.answers["/api/v2/oauth/token"] = (401, "{\"message\":\"invalid client\"}", [:])
        let standing = try await NetworkClient(exchange: tailscale.exchange).standing(Self.credential)
        #expect(!standing.accepted)
        #expect(!standing.tagReady)
        // A tag somebody took out again is also an answer: the credential works, the network is not ready.
        let noTag = StandIn.working(policy: Self.withoutTagOwners)
        let without = try await NetworkClient(exchange: noTag.exchange).standing(Self.credential)
        #expect(without.accepted && !without.tagReady)
        // A Tailscale this Mac cannot reach says nothing about the credential, so it still throws.
        let silent = StandIn()
        await #expect(throws: NetworkError.self) {
            try await NetworkClient(exchange: silent.exchange).standing(Self.credential)
        }
    }

    @Test func tailscaleBeingDownIsNotARevokedCredential() async throws {
        // The one that would lie to the owner: a 500, or no answer at all, must never read as "it was revoked".
        for status in [500, 502, 503, 404, 429] {
            let broken = StandIn()
            broken.answers["/api/v2/oauth/token"] = (status, "{\"message\":\"try later\"}", [:])
            let failed = await #expect(throws: NetworkError.self) {
                try await NetworkClient(exchange: broken.exchange).token(Self.credential)
            }
            #expect(failed != .notAccepted, "status \(status) must not read as a refused credential")
            #expect(failed == .refused("try later"))
        }
        // A connection that does not come up at all.
        let away = NetworkClient(exchange: { _ in throw URLError(.cannotConnectToHost) })
        await #expect(throws: NetworkError.unreachable) { try await away.token(Self.credential) }
        // And both statuses that do mean the credential.
        for status in NetworkClient.notAcceptedStatuses {
            let refused = StandIn()
            refused.answers["/api/v2/oauth/token"] = (status, "{\"error\":\"invalid_client\"}", [:])
            await #expect(throws: NetworkError.notAccepted) {
                try await NetworkClient(exchange: refused.exchange).token(Self.credential)
            }
        }
    }

    @Test func aPolicyFileThisAppCannotReadIsLeftAlone() async throws {
        let tailscale = StandIn.working(policy: "// a file with no object in it at all")
        await #expect(throws: NetworkError.policyNotUnderstood) {
            try await NetworkClient(exchange: tailscale.exchange).prepare(Self.credential)
        }
        #expect(!tailscale.calls.contains { $0.method == "POST" && $0.url.contains("/acl") })
    }

    @Test func oneOwnerOrNoneGoesInTheFile() async throws {
        // Two owners, so this app names none of them rather than choose for the owner.
        let many = "{\"users\":[{\"loginName\":\"a@example.com\",\"role\":\"owner\"},"
            + "{\"loginName\":\"b@example.com\",\"role\":\"owner\"}]}"
        let tailscale = StandIn.working(policy: "{}", users: many)
        _ = try await NetworkClient(exchange: tailscale.exchange).prepare(Self.credential)
        let posted = try #require(tailscale.calls.last { $0.method == "POST" })
        #expect(posted.body.contains("\"\(PrivateNetwork.tag)\": [],"))
        // A credential that may not read users is no reason to fail: the tag is written without an owner.
        let quiet = StandIn.working(policy: "{}")
        _ = try await NetworkClient(exchange: quiet.exchange).prepare(Self.credential)
        #expect(try #require(quiet.calls.last { $0.method == "POST" }).body.contains("\"\(PrivateNetwork.tag)\": [],"))
    }

    @Test func noRequestEverCarriesTheSecretInItsAddress() async throws {
        let tailscale = StandIn.working(policy: Self.withoutTagOwners,
                                        users: "{\"users\":[{\"loginName\":\"me@example.com\",\"role\":\"owner\"}]}")
        let client = NetworkClient(exchange: tailscale.exchange)
        _ = try await client.prepare(Self.credential)
        _ = try await client.key(for: "studio", with: Self.credential)
        #expect(tailscale.calls.count >= 4)
        for call in tailscale.calls {
            #expect(!call.url.contains("tskey-client-"), "a secret stood in an address: \(call.url)")
            #expect(!call.url.contains("secretpart"))
            // Only the token endpoint ever carries the secret, and only in its body.
            if URL(string: call.url)?.path != "/api/v2/oauth/token" {
                #expect(!call.body.contains("secretpart"))
            }
        }
        // Everything goes to Tailscale's own API and nowhere else.
        #expect(tailscale.calls.allSatisfy { URL(string: $0.url)?.host == "api.tailscale.com" })
        #expect(tailscale.calls.allSatisfy { URL(string: $0.url)?.scheme == "https" })
    }

    // MARK: - This Mac

    @Test func thisMacIsReadFromTailscalesOwnAnswer() {
        let running = MacNetwork.reading("""
        {"BackendState":"Running","Self":{"TailscaleIPs":["fd7a:115c::1","100.84.1.9"]},
         "CurrentTailnet":{"Name":"example.com"}}
        """)
        #expect(running.step == .connected)
        #expect(running.address == "100.84.1.9")
        #expect(running.tailnet == "example.com")
        #expect(running.isConnected)

        #expect(MacNetwork.reading("{\"BackendState\":\"NeedsLogin\"}").step == .notSignedIn)
        #expect(MacNetwork.reading("{\"BackendState\":\"NoState\"}").step == .notSignedIn)
        #expect(MacNetwork.reading("{\"BackendState\":\"Stopped\"}").step == .notConnected)
        #expect(MacNetwork.reading("{\"BackendState\":\"NeedsMachineAuth\"}").step == .notConnected)
        // Running, and with no address of the private network yet.
        #expect(MacNetwork.reading("{\"BackendState\":\"Running\",\"Self\":{\"TailscaleIPs\":[]}}").step
            == .notConnected)
        // Tailscale's own word is kept, so no screen has to invent one.
        #expect(MacNetwork.reading("{\"BackendState\":\"Stopped\"}").says == "Stopped")
        // Nothing, or something else entirely.
        #expect(MacNetwork.reading("").step == .notSignedIn)
        #expect(MacNetwork.reading("not json").step == .notSignedIn)
    }

    /// DevOps plan V4: a server's vault key is pinned only at an address that this Mac's own Tailscale says is that
    /// server, by the name the machine has in Tailscale (the first label of its MagicDNS name).
    @Test func aHostIsTheDeviceThatThisMacsTailscaleNames() {
        let status = """
        {"BackendState":"Running",
         "Self":{"HostName":"Sam's Mac","DNSName":"sams-mac.example.ts.net.","TailscaleIPs":["100.84.1.9","fd7a:115c::9"]},
         "Peer":{"nodekey:a":{"HostName":"ubuntu","DNSName":"worker-4.example.ts.net.","TailscaleIPs":["100.80.1.4","fd7a:115c::4"]},
                 "nodekey:b":{"HostName":"mac-studio","DNSName":"Sams-Mac-Studio.example.ts.net.","TailscaleIPs":["100.80.1.7"]},
                 "nodekey:c":{"DNSName":"","TailscaleIPs":["100.80.1.8"]}}}
        """
        #expect(MacNetwork.device(of: "100.80.1.4", in: status) == "worker-4")         // its MagicDNS name, not its host name
        #expect(MacNetwork.device(of: "fd7a:115c::4", in: status) == "worker-4")
        #expect(MacNetwork.device(of: "[fd7a:115c::4]", in: status) == "worker-4")
        #expect(MacNetwork.device(of: "worker-4", in: status) == "worker-4")
        #expect(MacNetwork.device(of: "worker-4.example.ts.net", in: status) == "worker-4")
        #expect(MacNetwork.device(of: "100.80.1.7", in: status) == "sams-mac-studio")
        #expect(MacNetwork.device(of: "100.84.1.9", in: status) == "sams-mac")             // this Mac itself
        #expect(MacNetwork.device(of: "100.80.1.8", in: status) == nil)                     // a device with no name
        #expect(MacNetwork.device(of: "192.168.1.20", in: status) == nil)                   // a LAN address is no device
        #expect(MacNetwork.device(of: "100.80.1.4", in: "not json") == nil)
    }

    @Test func aMacWithNoTailscaleSaysSo() {
        #expect(MacNetwork.command(exists: { _ in false }) == nil)
        // The standalone variant's own link comes first, because that is the one Tailscale recommends.
        #expect(MacNetwork.command(exists: { $0 != "/usr/local/bin/tailscale" })
            == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(MacNetwork.command(exists: { _ in true }) == "/usr/local/bin/tailscale")
    }

    @Test func onlyAnInstallerTailscaleSignedIsOpened() {
        let real = """
        Package "ts.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Tailscale Inc. (W5364U7YZB)
        """
        #expect(MacNetwork.isTailscales(real))
        // Somebody else's package, and an unnotarized one, are both refused.
        #expect(!MacNetwork.isTailscales(real.replacingOccurrences(of: "Tailscale Inc. (W5364U7YZB)",
                                                                  of2: "Someone Else (XXXXXXXXXX)")))
        #expect(!MacNetwork.isTailscales(real.replacingOccurrences(
            of: "Notarization: trusted by the Apple notary service", with: "Notarization: not notarized")))
        #expect(!MacNetwork.isTailscales(""))
        // It comes from Tailscale's own package server, over HTTPS.
        #expect(MacNetwork.download.host == "pkgs.tailscale.com")
        #expect(MacNetwork.download.scheme == "https")
    }

    // MARK: - What the owner is told to open

    @Test func theOwnerIsSentToTailscalesOwnConsole() {
        // The console moved to this host; a page of the old one would be a dead end.
        #expect(PrivateNetwork.console.host == "console.tailscale.com")
        #expect(PrivateNetwork.console.scheme == "https")
        #expect(PrivateNetwork.console.path == "/admin/settings/trust-credentials")
        #expect(PrivateNetwork.tag == "tag:founderizer")
        #expect(PolicyFile.isTag(PrivateNetwork.tag))
    }
}

private extension String {
    /// Two replacements read better than nested calls in one expectation.
    func replacingOccurrences(of first: String, of2 second: String) -> String {
        replacingOccurrences(of: first, with: second)
    }
}

