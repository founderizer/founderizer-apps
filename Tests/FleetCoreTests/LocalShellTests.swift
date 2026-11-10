#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// One program on this Mac, with its input on standard input (`LocalShell`).
struct LocalShellTests {
    /// 7 November 2026: the door round gave a server the door's bundle on standard input while that server went down
    /// for its reboot. The write to the closed pipe raised SIGPIPE, and the whole app stopped. A program that ends
    /// before it reads its input now gives its answer, and this process goes on.
    @Test func aProgramThatReadsNoneOfItsInputStopsNothingHere() async throws {
        let answer = try await LocalShell.run("/bin/sh", ["-c", "echo early; exit 3"], stdin: Data(count: 4_000_000),
                                              timeout: 30)
        #expect(answer.status == 3)
        #expect(answer.lines == ["early"])
    }
}
#endif
