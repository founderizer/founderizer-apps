#if os(macOS)
import Foundation
import Testing

/// **How the Mac app's install model begins an install** (`MachineInstallModel` in the app, which no test target
/// imports, so its source is read, as `InstallCauseTests` reads it).
struct InstallStartTests {
    /// **Each start of an install begins with no wait for the network of the install before it.** A Mac's link did
    /// not: after a join that stopped at the wait for the network, the link was drawn as the network's question
    /// while it ran and after its good end, and a link that was refused at once said that wait beside its own stop.
    @Test func eachStartOfAnInstallClearsTheWaitForTheNetwork() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: app.appendingPathComponent("Sources/Founderizer/MachineInstallView.swift"), encoding: .utf8)
        let lines = model.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // The hub's install, a server's join, a Mac's link, a Mac's link that goes on after its stop, and "again".
        let clears = lines.filter { $0.contains("failure = nil; failureDetail = nil") }
        #expect(clears.count >= 5)
        for line in clears { #expect(line.contains("needsNetworkKey = false; networkFailure = nil"), "\(line)") }
        // A link that cannot start: both refusals through the one function, which clears the wait too.
        let refusal = try #require(lines.firstIndex(of: "private func cannotLink(_ words: String?) {"))
        let body = lines[refusal...].prefix { $0 != "}" }
        #expect(body.contains("needsNetworkKey = false; networkFailure = nil"))
        #expect(body.contains { $0.hasPrefix("stop = .cannotStart; cause = nil") })
        #expect(lines.filter { $0.hasPrefix("cannotLink(") }.count == 2)
        #expect(!lines.contains { $0.hasPrefix("stop = .cannotStart") && !body.contains($0) })
    }
}
#endif
