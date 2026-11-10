import Foundation
import JavaScriptCore
import Testing
@testable import FleetVaultCore

/// The look at the page after a form (`checkScript`): the script as the vault generates it, run in a JavaScript
/// engine. A small stand-in is the page: its origin, how far it is loaded, and the selectors that find a field.
struct VaultBrowserFlowTests {
    static let origin = "http://100.96.10.20:8765"
    static let password = "input[type=password]"

    /// The answer of the generated script for a page, and the selectors that the script asked the page for.
    static func look(at page: String = origin, state: String, fields: [String] = []) throws -> (answer: String, asked: [String]) {
        let context = try #require(JSContext())
        context.setObject(["origin": page, "state": state, "fields": fields], forKeyedSubscript: "page" as NSString)
        context.evaluateScript("""
            var asked = [];
            var location = { origin: page.origin };
            var document = { readyState: page.state, querySelector: function (selector) {
                asked.push(selector);
                return page.fields.indexOf(selector) < 0 ? null : {};
            } };
            """)
        let answer = try #require(context.evaluateScript(try VaultBrowser.checkScript(origin))?.toString())
        #expect(context.exception == nil)
        return (answer, context.objectForKeyedSubscript("asked")?.toArray() as? [String] ?? [])
    }

    @Test func aPageWithNoFieldIsNotSignedInWhileItIsStillLoading() throws {
        let code = VaultBrowser.otpSelector
        // The fault: a code page that came in two parts had no field yet at the look, and the answer was `none`,
        // which the sign-in takes for "signed in". A page that is still being read can get its field later.
        #expect(try Self.look(state: "loading").answer == "loading")
        // A page that is read to its end and has no field is the signed-in page, as before.
        #expect(try Self.look(state: "interactive").answer == "none")
        #expect(try Self.look(state: "complete").answer == "none")
        for state in ["loading", "interactive", "complete"] {
            // A field that is there is seen in each state, and the password field comes first.
            #expect(try Self.look(state: state, fields: [Self.password]).answer == "form")
            #expect(try Self.look(state: state, fields: [code]).answer == "otp")
            #expect(try Self.look(state: state, fields: [Self.password, code]).answer == "form")
            // A page of another origin gets no look at all.
            let other = try Self.look(at: "http://100.96.10.20:8766", state: state, fields: [Self.password, code])
            #expect(other.answer == "wrong-origin" && other.asked.isEmpty)
        }
        // The script asks for the password field, then for the code field, with the vault's own selectors.
        #expect(try Self.look(state: "complete").asked == [Self.password, code])
        #expect(try Self.look(state: "loading", fields: [Self.password]).asked == [Self.password])
        // `signIn` takes only `none` for signed in and only `otp` for a code page: each other answer is a refusal.
        #expect(!["none", "otp"].contains(try Self.look(state: "loading").answer))
    }
}
