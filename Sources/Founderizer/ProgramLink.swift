import FleetOwnerAPI
import Foundation
import Security

/// **The link to the app's own program for the owner's AI agent** (`~/.founderizer/cli`, `CLILink`): kept at each start,
/// off the main thread, so it never holds the start back, and with no screen, no alert and no line that a person reads.
/// The rules of when it is set are `CLILink.step`'s; this file only reads the facts that need the app itself.
enum ProgramLink {
    static func keep() {
        let bundle = Bundle.main.bundleURL
        // As FleetStore reads it: a start with `-hubAddress` is a test copy, which never gives the owner's agent its program.
        let hubAddressArgument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["hubAddress"] != nil
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            CLILink.keep(bundle: bundle, home: home, signedWithDeveloperID: signedWithDeveloperID(),
                         hubAddressArgument: hubAddressArgument)
        }
    }

    /// Whether this running app is signed with a Developer ID (Apple's anchor, a Developer ID certificate authority and
    /// a Developer ID Application leaf): an ad hoc or a development build is not.
    private static func signedWithDeveloperID() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
