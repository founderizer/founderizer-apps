import Foundation

/// **The app's own words for the codes of the hub's refusals** (the design `hub-refusal-words-design.md`; UI-API.md 1.181;
/// the owner's "Yes, as shown" of 16 November 2026). The hub writes a `code` beside the English line of a refusal, and the
/// values inside that line as `names`. This table has the app's sentence for each code that it knows, so that a refusal
/// is read in the language of the device (`HubRefusal.words`): it reached a Spanish Mac in English.
///
/// **One `switch`, one case for each code of `app/vectors/refusal-codes.json`.** The key of each case is the hub's
/// English, character for character, with `%@` where the hub has a `{name}`, so that `l10n.py sync` and `check` see it
/// and the Spanish is the catalog's, as for every other word of the app. `RefusalWordsTests` reads the same vectors: a
/// code with no case, another English or other holes fails there, and never on a screen.
///
/// **The hub's English wins on English.** The table's words show only when the lookup gave words of another language.
/// On a device whose language is English, for a code that is not here, for a key that the catalog has no words for, and
/// for a refusal that lacks a name that its words hold, `words(for:)` is nil and the hub's own line shows, exactly as it
/// came. So a drift between the hub's English and this table never reaches a screen on English.
enum RefusalWords {
    /// The app's words for this refusal in the language of the device, or nil when the hub's own line stands.
    static func words(for refusal: HubRefusal) -> String? {
        guard let code = refusal.code,
              let own = sentence(code, refusal.names, say: { String(l10n: $0) }),
              let english = sentence(code, refusal.names, say: Self.english) else { return nil }
        // The lookup gave the key back: no language, no table, or no entry for it.
        return own == english ? nil : own
    }

    /// A key with its values in, as the lookup gives it where there is no table of words for it: the English. A table
    /// that no bundle has gives each key back, in every language (internal, for the test that holds each case to the
    /// hub's vector).
    static func english(_ value: String.LocalizationValue) -> String {
        String(localized: value, table: "None", bundle: Localized.bundle, locale: Localized.digits)
    }

    /// The sentence of `code`, said by `say`, or nil for a code that has no case here and for a name that its words
    /// hold and `names` lacks. Internal, for the test that holds each case to the hub's vector.
    static func sentence(_ code: String, _ names: [String: RefusalName],
                         say: (String.LocalizationValue) -> String) -> String? {
        let server = names["server"]?.written, address = names["address"]?.written, agent = names["agent"]?.written
        let provider = names["provider"]?.written
        switch code {
        case "hub_changed":
            return say("hub generation changed; refresh state")
        case "hub_changed_sending":
            return say("hub generation changed; refresh state before sending")
        case "team_changed":
            return say("team.json changed meanwhile; reload it")
        case "team_changed_lines":
            return say("team.json changed meanwhile; reload the reporting lines")
        case "no_such_agent":
            return say("no such agent")
        case "no_such_server":
            return say("no such server")
        case "no_such_task":
            return say("no such task")
        case "login_as_text":
            return say("a registered login cannot be sent as text")
        case "login_as_file":
            return say("a registered login cannot be sent as a file")
        case "login_not_shown":
            return say("registered login text cannot be displayed")
        case "command_reused":
            return say("request_id was already used for a different command")
        case "command_reused_message":
            return say("request_id was already used for an owner message; send the answer with a new one")
        case "command_reused_file":
            return say("request_id was already used for another file")
        case "command_reused_content":
            return say("request_id was already used for different content or recipient")
        case "command_interrupted":
            return say("this command was interrupted and the hub does not know what came of it. Read the thing it was about, and send the command again with a new request_id if it did not take effect")
        case "revision_unreadable":
            return say("the hub cannot read its own revision")
        case "server_silent":
            guard let server else { return nil }
            return say("\(server) sent no reading in the last 10 minutes: check that it is on")
        case "server_no_service":
            guard let server else { return nil }
            return say("\(server) has no server service: it did not join with a join code")
        case "request_answered":
            return say("owner request is already answered")
        case "request_unknown":
            return say("owner request does not exist")
        case "request_unknown_ended":
            return say("owner request does not exist: a request whose task ended is gone with it")
        case "not_owner_device":
            guard let address else { return nil }
            return say("\(address) is not an owner device. See \"owner_devices\" in team.json.")
        case "not_owner_device_no_code":
            guard let address else { return nil }
            return say("\(address) is not an owner device, and that is not a code for a new one")
        case "agent_mid_turn":
            guard let agent else { return nil }
            return say("\(agent) is in the middle of a turn. Move it when the turn ends.")
        case "agent_open_signin":
            guard let agent else { return nil }
            return say("\(agent) has an open sign-in. Finish it or let it run out, then try again.")
        // **An account with a key or a model server** (the AI providers build; `hub.ACCOUNT_WORDS`, UI-API.md 1.165 and
        // 1.175, decision D7): the owner's approved words of round 2, sentences 1 to 8 (ai-providers-step-5-answers.md).
        // The hub keeps them apart from `refusal_words.py` until the lane AI providers B moves them into it, so they
        // are not in `app/vectors/refusal-codes.json` yet (`ModelAccountsTests` holds them to the hub's English).
        case "plain_http":
            return say("Plain http works only over Tailscale or on the agent's own server. Use that machine's Tailscale address, or https.")
        case "address":
            return say("Write the address as http:// or https://, then the host, and a port and a path if it has them.")
        case "pooled":
            return say("The fleet manager may give this key. Set it to You alone in Settings › Secrets, then save again.")
        case "placement":
            return say("Founderizer no longer has this key or address. Start again from Add agent.")
        case "open":
            guard let server else { return nil }
            return say("\(server) has an agent on a model server with no key, so it takes no other agent. Choose another server.")
        case "change":
            guard let agent, let provider else { return nil }
            return say("\(agent) stays on \(provider). For another AI, add a new agent.")
        case "change_server":
            guard let agent else { return nil }
            return say("\(agent) stays on its model server. For another AI, add a new agent.")
        case "mac":
            guard let server, let provider else { return nil }
            return say("\(server) is a Mac. An agent on \(provider) needs a Linux server: choose another one.")
        case "older":
            guard let server else { return nil }
            return say("\(server) runs an older Founderizer that cannot do this yet. It updates itself when it has no job; then try again.")
        default:
            return nil
        }
    }
}
