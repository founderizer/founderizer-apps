import CryptoKit
import Foundation
import Testing
@testable import FleetCore

private let revision = String(repeating: "a", count: 40)
private let testContext = ArtifactContext(hub: URL(string: "http://127.0.0.1:8765/")!, database: "test-generation", taskID: 7)

private func entry(_ data: Data = Data("plain text\n".utf8), path: String = "outputs/result.txt", mime: String = "text/plain") -> CheckedArtifact {
    CheckedArtifact(path: path, commit: revision,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    bytes: data.count, mime: mime)
}

private func listData(_ files: [CheckedArtifact], db: String = "test-generation", task: Int = 7) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["db": db, "task": task, "artifacts": files.map {
        ["path": $0.path, "commit": $0.commit, "sha256": $0.sha256, "bytes": $0.bytes, "mime": $0.mime] as [String: Any]
    }])
}

private func response(_ artifact: CheckedArtifact, overrides: [String: String] = [:], url: URL? = nil) throws -> HTTPURLResponse {
    var headers = ["X-Fleet-DB": testContext.database, "X-Fleet-Task": "7", "X-Fleet-Commit": revision,
                   "Content-Type": artifact.mime, "Content-Length": String(artifact.bytes)]
    headers.merge(overrides) { _, new in new }
    return HTTPURLResponse(url: try url ?? testContext.fileURL(artifact), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
}

@Test func artifactPathsCannotEscapeOutputsOrUseActiveDocumentTypes() throws {
    for path in ["/outputs/a.txt", "https://other/a.txt", "outputs/../a.txt", "outputs/a/../../b.txt",
                 "outputs//a.txt", "outputs/./a.txt", "outputs/%2e%2e/a.txt", "outputs/a\\b.txt",
                 "outputs/a\n.txt", "outputs/a.html", "outputs/a.svg", "outputs/a.pdf", "outputs/a.sh"] {
        #expect(throws: (any Error).self) { try entry(path: path).validate() }
    }
    let valid = entry(path: "outputs/nested/plain file.md")
    try valid.validate()
    let url = try testContext.fileURL(valid)
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(url.host == testContext.hub.host)
    #expect(parts.path == "/ui/tasks/7/artifact")
    #expect(parts.queryItems?.first(where: { $0.name == "path" })?.value == valid.path)
    #expect(parts.queryItems?.first(where: { $0.name == "db" })?.value == testContext.database)
    let invalidHub = ArtifactContext(hub: URL(string: "http://localhost/unexpected?x=1")!, database: "test", taskID: 7)
    #expect(throws: (any Error).self) { try invalidHub.fileURL(valid) }
}

@Test func artifactListBindsDatabaseTaskPathsAndSingleRevision() throws {
    let file = entry()
    let list = try ArtifactList.decode(listData([file]), context: testContext)
    #expect(list.artifacts == [file])
    #expect(try ArtifactList.decode(listData([]), context: testContext).artifacts.isEmpty)
    #expect(throws: (any Error).self) { try ArtifactList.decode(listData([file], db: "changed"), context: testContext) }
    #expect(throws: (any Error).self) { try ArtifactList.decode(listData([file], task: 8), context: testContext) }
    #expect(throws: (any Error).self) { try ArtifactList.decode(listData([file, file]), context: testContext) }
    let otherRevision = CheckedArtifact(path: "outputs/second.txt", commit: String(repeating: "b", count: 40),
                                        sha256: file.sha256, bytes: file.bytes, mime: file.mime)
    #expect(throws: (any Error).self) { try ArtifactList.decode(listData([file, otherRevision]), context: testContext) }
}

@Test func artifactMetadataEnforcesMimeAndByteLimits() throws {
    let file = entry()
    for invalid in [
        CheckedArtifact(path: file.path, commit: "main", sha256: file.sha256, bytes: 1, mime: file.mime),
        CheckedArtifact(path: file.path, commit: revision, sha256: "wrong", bytes: 1, mime: file.mime),
        CheckedArtifact(path: file.path, commit: revision, sha256: file.sha256, bytes: -1, mime: file.mime),
        CheckedArtifact(path: file.path, commit: revision, sha256: file.sha256, bytes: 256 * 1024 + 1, mime: file.mime),
        CheckedArtifact(path: "outputs/a.png", commit: revision, sha256: file.sha256, bytes: 8 * 1024 * 1024 + 1, mime: "image/png"),
        CheckedArtifact(path: "outputs/a.png", commit: revision, sha256: file.sha256, bytes: 1, mime: "text/plain"),
        CheckedArtifact(path: file.path, commit: revision, sha256: file.sha256, bytes: 1, mime: "text/html")
    ] { #expect(throws: (any Error).self) { try invalid.validate() } }
}

@Test func artifactResponseMustMatchExactIdentityMimeAndLength() throws {
    let file = entry()
    try ArtifactValidation.response(response(file), artifact: file, context: testContext)
    for headers in [["X-Fleet-DB": "changed"], ["X-Fleet-Task": "8"], ["X-Fleet-Commit": String(repeating: "b", count: 40)],
                    ["Content-Type": "text/html"], ["Content-Type": "text/plain; charset=iso-8859-1"],
                    ["Content-Length": String(file.bytes + 1)], ["Content-Length": "999999999"], ["Content-Encoding": "gzip"]] {
        #expect(throws: (any Error).self) { try ArtifactValidation.response(response(file, overrides: headers), artifact: file, context: testContext) }
    }
    let foreign = URL(string: "http://other.invalid/ui/tasks/7/artifact")!
    #expect(throws: (any Error).self) { try ArtifactValidation.response(response(file, url: foreign), artifact: file, context: testContext) }
}

@Test func artifactChecksumAndActualByteCountAreBothRequired() throws {
    let data = Data("hello".utf8)
    let file = entry(data)
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(Data("HELLO".utf8), artifact: file) }
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(Data("hell".utf8), artifact: file) }
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(Data("hello!".utf8), artifact: file) }
    guard case .text(let text) = try ArtifactValidation.payload(data, artifact: file) else {
        Issue.record("Expected plain text"); return
    }
    #expect(text == "hello")
}

@Test func textRemainsPlainAndRequiresValidUTF8() throws {
    let data = Data("<script>alert(1)</script> [link](https://example.com)".utf8)
    guard case .text(let text) = try ArtifactValidation.payload(data, artifact: entry(data)) else {
        Issue.record("Expected plain text"); return
    }
    #expect(text == String(data: data, encoding: .utf8))
    let invalid = Data([0xff, 0xfe])
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(invalid, artifact: entry(invalid)) }
    guard case .text(let empty) = try ArtifactValidation.payload(Data(), artifact: entry(Data())) else {
        Issue.record("Expected empty text"); return
    }
    #expect(empty.isEmpty)
}

@Test func imageBytesMustBeTheDeclaredRasterFormat() throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1sAAAAASUVORK5CYII="))
    guard case .image = try ArtifactValidation.payload(png, artifact: entry(png, path: "outputs/pixel.png", mime: "image/png")) else {
        Issue.record("Expected PNG image"); return
    }
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(png, artifact: entry(png, path: "outputs/wrong.jpg", mime: "image/jpeg")) }
    let html = Data("<html>Not an image</html>".utf8)
    #expect(throws: (any Error).self) { try ArtifactValidation.payload(html, artifact: entry(html, path: "outputs/fake.png", mime: "image/png")) }
}
