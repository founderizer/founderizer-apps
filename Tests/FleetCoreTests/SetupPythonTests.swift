#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The Python of the bundled installer (`SetupPython`): never Apple's placeholder for a Mac with no developer tools.
struct SetupPythonTests {
    private static let tools = "/Library/Developer/CommandLineTools"

    private func choose(there: Set<String>, tools: String?) -> (python: String?, askedForTools: Bool) {
        var asked = false
        let python = SetupPython.choose(isExecutable: { there.contains($0) },
                                        developerDirectory: { asked = true; return tools })
        return (python, asked)
    }

    /// A clean Mac: the placeholder is there and can be executed, and no developer tools are on the Mac.
    @Test func thePlaceholderOfAMacWithNoDeveloperToolsIsNoPython() {
        let found = choose(there: ["/usr/bin/python3"], tools: nil)
        #expect(found.python == nil)
        #expect(found.askedForTools)
    }

    @Test func theSystemPythonCountsWithTheDeveloperTools() {
        #expect(choose(there: ["/usr/bin/python3", Self.tools + "/usr/bin/python3"], tools: Self.tools).python
                == "/usr/bin/python3")
        let xcode = "/Applications/Xcode.app/Contents/Developer"
        #expect(choose(there: ["/usr/bin/python3", xcode + "/usr/bin/python3"], tools: xcode).python == "/usr/bin/python3")
    }

    /// A developer folder is selected, and it holds no Python: the placeholder would still ask to install the tools.
    @Test func aDeveloperFolderWithNoPythonDoesNotCount() {
        #expect(choose(there: ["/usr/bin/python3"], tools: Self.tools).python == nil)
        #expect(choose(there: ["/usr/bin/python3", Self.tools + "/usr/bin/python3"], tools: "").python == nil)
    }

    /// The owner's own Python comes first, in the order the service has always used, and the tools are not asked for.
    @Test func aPythonOfTheOwnersOwnComesFirst() {
        let both = choose(there: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"], tools: nil)
        #expect(both.python == "/opt/homebrew/bin/python3")
        #expect(!both.askedForTools)
        #expect(choose(there: ["/usr/local/bin/python3", "/usr/bin/python3"], tools: nil).python == "/usr/local/bin/python3")
    }

    @Test func aMacWithNoPythonAtAllHasNone() {
        #expect(choose(there: [], tools: Self.tools).python == nil)
    }

    /// The developer tools hold a Python, and the system's own file is not there: there is nothing to run.
    @Test func thePythonOfTheToolsAloneIsNotTheSystemPython() {
        #expect(choose(there: [Self.tools + "/usr/bin/python3"], tools: Self.tools).python == nil)
    }
}
#endif
