import Foundation
import Testing
@testable import FleetCore

/// GitHub's answers by address, for the tests of the manifest flow's two calls.
final class GitHubStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, String)] = [:]
    static let lock = NSLock()

    static func session(_ answers: [String: (Int, String)]) -> URLSession {
        lock.lock(); self.answers.merge(answers) { $1 }; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.absoluteString ?? "")
        Self.lock.lock(); let answer = Self.answers[key] ?? (404, "{}"); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The coordinator, 6 November 2026 (DevOps plan 13, item 4, and plan 2.20): an account that no App of the door reaches
/// gets a private App of its own through GitHub's manifest flow, with its permissions filled in, no webhook, a return
/// to this Mac's loopback address, and nothing of Founderizer's on his screen.
struct GitHubManifestTests {
    @Test func theManifestIsAPrivateAppWithTheDoorsPermissionsAndNoWebhook() throws {
        let text = try GitHubManifest.manifest(owner: "Globex", redirect: URL(string: "http://127.0.0.1:5123/done")!,
                                               suffix: "3f9a")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["name"] as? String == "Globex Founderizer 3f9a")
        #expect((object["name"] as? String ?? "").count <= 34)
        #expect(object["public"] as? Bool == false)
        #expect(object["redirect_url"] as? String == "http://127.0.0.1:5123/done")
        #expect(object["hook_attributes"] == nil)
        #expect((object["default_events"] as? [String]) == [])
        let permissions = try #require(object["default_permissions"] as? [String: String])
        #expect(permissions["contents"] == "write" && permissions["workflows"] == "write" && permissions["secrets"] == "write")
        #expect(permissions["metadata"] == "read" && permissions["vulnerability_alerts"] == "read")
        #expect(permissions["administration"] == "write" && permissions["repository_creation"] == "write")   // N2
        #expect(permissions["issues"] == "write")       // 12 November 2026: a token reads issues and, from write, comments
        #expect(GitHubManifest.name(owner: String(repeating: "a", count: 39), suffix: "ffff").count == 34)
    }

    @Test func thePagesAreGitHubsOwn() {
        #expect(GitHubManifest.newAppPage(owner: "Acme", organization: true, state: "s1").absoluteString
                == "https://github.com/organizations/Acme/settings/apps/new?state=s1")
        #expect(GitHubManifest.newAppPage(owner: "solo", organization: false, state: "s2").absoluteString
                == "https://github.com/settings/apps/new?state=s2")
        #expect(GitHubManifest.installPage(slug: "acme-founderizer-3f9a")?.absoluteString
                == "https://github.com/apps/acme-founderizer-3f9a/installations/new")
        #expect(GitHubManifest.installPage(slug: "evil.example/x") == nil)
    }

    @Test func theStartPageHasNoWordsAndSendsTheFormAsItIs() throws {
        let manifest = #"{"name":"a \"b\" <c>","url":"https://founderizer.com"}"#
        let page = GitHubManifest.startPage(action: URL(string: "https://github.com/settings/apps/new?state=s")!,
                                            manifest: manifest)
        #expect(page.contains(#"action="https://github.com/settings/apps/new?state=s""#))
        #expect(page.contains("value=\"{&quot;name&quot;:&quot;a \\&quot;b\\&quot; &lt;c&gt;&quot;"))
        #expect(!page.contains("<c>"))
        let body = try #require(page.range(of: "<body")).lowerBound
        #expect(page[body...].replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).isEmpty)
    }

    @Test func onlyTheReturnWithThisFlowsStateCarriesACode() {
        #expect(GitHubManifest.code(target: "/done?code=abc123&state=st8", state: "st8") == "abc123")
        #expect(GitHubManifest.code(target: "/done?code=abc123&state=other", state: "st8") == nil)
        #expect(GitHubManifest.code(target: "/done?code=abc123", state: "st8") == nil)
        #expect(GitHubManifest.code(target: "/elsewhere?code=abc123&state=st8", state: "st8") == nil)
        #expect(GitHubManifest.code(target: "/done?code=a%20b&state=st8", state: "st8") == nil)
    }

    @Test func theCodeGivesTheAppAndItsKeyAndTheAccountItsKind() async throws {
        let made = #"{"id": 777, "slug": "acme-founderizer-3f9a", "pem": "-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----\n", "owner": {"login": "Acme"}, "client_secret": "s"}"#
        let session = GitHubStub.session([
            "POST https://api.github.com/app-manifests/c0de1/conversions": (201, made),
            "POST https://api.github.com/app-manifests/c0de2/conversions": (404, "{}"),
            "GET https://api.github.com/users/Acme": (200, #"{"login": "Acme", "id": 42, "type": "Organization"}"#),
            "GET https://api.github.com/users/solo": (200, #"{"login": "solo", "id": 7, "type": "User"}"#)])
        let app = try await GitHubManifest.convert(code: "c0de1", session: session)
        #expect(app.id == 777 && app.slug == "acme-founderizer-3f9a" && app.owner.login == "Acme")
        await #expect(throws: GitHubManifest.Failure.refused(404)) {
            try await GitHubManifest.convert(code: "c0de2", session: session)
        }
        await #expect(throws: GitHubManifest.Failure.answer) {
            try await GitHubManifest.convert(code: "../x", session: session)
        }
        #expect(try await GitHubManifest.account("Acme", session: session).isOrganization)
        #expect(try await !GitHubManifest.account("solo", session: session).isOrganization)
    }

    #if os(macOS)
    @Test func theListenerServesItsPageAndTakesGitHubsReturnOnce() async throws {
        let listener = GitHubManifestListener(state: "st8") { code in
            URL(string: "https://github.com/apps/x/installations/new?code=\(code)")!
        }
        let port = try listener.start()
        defer { listener.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: NoFollow(), delegateQueue: nil)
        func get(_ path: String) async throws -> HTTPURLResponse {
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            return try #require(response as? HTTPURLResponse)
        }
        #expect(try await get("/start").statusCode == 404)          // before the page names its port
        listener.serve("<!doctype html><html><body></body></html>")
        #expect(try await get("/start").statusCode == 200)
        #expect(try await get("/done?code=abc&state=wrong").statusCode == 404)
        let back = try await get("/done?code=abc&state=st8")
        #expect(back.statusCode == 302)
        #expect(back.value(forHTTPHeaderField: "Location") == "https://github.com/apps/x/installations/new?code=abc")
    }
    #endif
}

/// A redirect is read as an answer, so the test sees the 302 itself.
final class NoFollow: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
