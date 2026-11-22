import Foundation

/// **The app's own words for the codes of the hub's refusals** (the design `hub-refusal-words-design.md`; UI-API.md 1.181;
/// the owner's "Yes, as shown" of 16 November 2026). The hub writes a `code` beside the English line of a refusal, and the
/// values inside that line as `names`. This table has the app's sentence for each code that it knows, so that a refusal
/// is read in the language of the device (`HubRefusal.words`): it reached a Spanish Mac in English.
///
/// **One `switch`, one case for each code of `app/vectors/refusal-codes.json`.** The key of each case is the hub's
/// English, character for character, with `%@` where the hub has a `{name}`, so that `l10n.py sync` and `check` see it
/// and the Spanish is the catalog's, as for every other word of the app. `RefusalWordsVectorsTests` reads the same
/// vectors: a code with no case, another English or other holes fails there, and never on a screen. **Every code of the
/// vectors has its case** since 19 November 2026, when the owner said "Yes, all 29" to the Spanish of the 29 that had
/// waited for it; a new code of the hub waits in that test's `waiting` until his yes to the Spanish of its slice
/// (COORDINATION.md rule 8).
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
        // The names of the 29 codes that waited for the owner's yes. A count (`megabytes`, `days`, `http_status`, `most`)
        // is read as its digits, like any other name.
        let registry = names["registry"]?.written, name = names["name"]?.written, httpStatus = names["http_status"]?.written
        let megabytes = names["megabytes"]?.written, version = names["version"]?.written, day = names["day"]?.written
        let days = names["days"]?.written, newest = names["newest"]?.written, reason = names["reason"]?.written
        let most = names["most"]?.written
        let account = names["account"]?.written         // a Drive folder's account (UI-API.md 1.255)
        let repo = names["repo"]?.written               // one of the product's own repositories (repo_vendor)
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
        // **An agent's browser on a Linux server** (build plan 04, S3; UI-API.md 1.218): its Shell box (D2), a server
        // that runs none (D8), and a server with no room for it (D6). The owner's "Yes, as written" of 18 November 2026
        // to these words in English and Spanish.
        case "browser_shell_off":
            guard let agent else { return nil }
            return say("\(agent) cannot have a browser on a Linux server while its Shell box is off: turn its Shell box on, or its Browser box off")
        case "browser_server":
            guard let server else { return nil }
            return say("\(server) runs no browser for an agent: in this version only a Linux server with x86 Ubuntu 24.04 or 26.04 that is not the hub's own server runs one")
        case "browser_no_room":
            guard let server, let agent else { return nil }
            return say("\(server) has no room for the browser of \(agent) beside its other agents: turn its Browser box off first, or move it to a server with more memory")
        // The move's two cases of D6 (20 November 2026): a server whose room is full with the agent counted there,
        // and one whose reading does not say its room yet. `browser_no_room` stays for a hub that sends it.
        case "browser_no_place":
            guard let server, let agent else { return nil }
            return say("\(server) has no room for the browser of \(agent): turn its Browser box off first, or move it to a server with more memory")
        case "browser_room_unknown":
            guard let server, let agent else { return nil }
            return say("\(server) has not said how much memory it has for browsers: turn the Browser box of \(agent) off first, or move it to another server")
        // **Take over for an agent on a Linux server** (build plan 04, S6; UI-API.md 1.225): the item, the agent's
        // screen, and what its server said. The owner's "Yes, as written" of 19 November 2026 to these words in
        // English and Spanish.
        case "takeover_closed":
            return say("This step is answered or no longer open")
        case "takeover_no_screen":
            guard let agent else { return nil }
            return say("\(agent)'s screen cannot be opened now: its server or its Founderizer is not ready for it")
        case "takeover_late":
            guard let agent else { return nil }
            return say("\(agent)'s server did not open its screen in time: press Take over again")
        case "takeover_no_browser":
            guard let agent else { return nil }
            return say("\(agent)'s browser does not run now, so there is no screen to take over")
        case "takeover_provider":
            guard let agent else { return nil }
            return say("\(agent)'s browser shows an AI provider's site, which is never taken over")
        case "takeover_screen_failed":
            guard let agent else { return nil }
            return say("\(agent)'s server could not share its screen: press Take over again")
        // **The 29 codes that waited for the owner's yes to their Spanish** (his "Yes, all 29" of 19 November 2026: the 23
        // that he saw on 16 November and Telegram's six of 19 November), in the order of the lanes that added them.
        //
        // **A rule that sends** (UI-API.md 1.184).
        case "time_passed":
            return say("this time has passed; change the time first")
        // **Google's Connect and Disconnect** (UI-API.md 1.185).
        case "google_file_mode":
            return say("the Google file of the hub must be a regular file of the hub user with mode 600")
        case "google_file_unreadable":
            return say("the Google file of the hub cannot be read: it is not a JSON object with accounts")
        case "google_no_client":
            return say("This hub's release has no Google client. Update the hub, then connect again.")
        case "google_no_secret":
            return say("Founderizer's Google app cannot be read from founderizer.com now, so nothing was started. Try again in a few minutes.")
        case "connect_stale":
            return say("This Connect expired, or another one took its place. Start Connect again.")
        case "google_refused":
            guard let reason else { return nil }
            return say("Google refused: \(reason). Start Connect again.")
        case "google_revoked_during":
            return say("A Disconnect of this account came during this Connect, so nothing was connected. Start Connect again.")
        // **A Drive folder of one account for some agents** (UI-API.md 1.255; the owner's "Yes, ship them" of 20 November
        // 2026 to their Spanish).
        case "drive_folder_link":
            return say("That is not the link of a Drive folder.")
        case "drive_folder_account":
            guard let account else { return nil }
            return say("\(account) is not connected for Google Drive now. Connect it again.")
        case "drive_folder_unseen":
            guard let account else { return nil }
            return say("\(account) cannot open this folder. Share it with \(account), or connect the account that has it.")
        case "drive_folder_file":
            return say("That is the link of a file, not of a folder.")
        case "drive_folder_google":
            guard let reason else { return nil }
            return say("Google did not answer about this folder: \(reason). Try again.")
        // **A grant of one of the product's own repositories** (POST /ui/team/repos, POST /ui/resources; the owner's
        // "Yes, use it" of 20 November 2026 to its Spanish).
        case "repo_vendor":
            guard let repo else { return nil }
            return say("The door refuses \(repo) in every fleet, so no grant of it works: leave it out.")
        // **The MCP server form** (UI-API.md 1.187): a package at a registry, the MCP Registry, and a server's OAuth.
        case "package_unknown":
            guard let registry, let name else { return nil }
            return say("\(registry) has no package \(name)")
        case "package_unread":
            guard let registry, let name, let httpStatus else { return nil }
            return say("\(registry) did not give the record of \(name) (\(httpStatus))")
        case "package_registry_away":
            guard let registry else { return nil }
            return say("\(registry) cannot be reached now")
        case "package_record_large":
            guard let name, let registry, let megabytes else { return nil }
            return say("the record of \(name) at \(registry) is larger than \(megabytes) MB")
        case "package_no_record":
            guard let registry, let name else { return nil }
            return say("\(registry) gave no record of \(name)")
        case "package_no_version":
            guard let registry, let version, let name else { return nil }
            return say("\(registry) has no version \(version) of \(name)")
        case "package_too_new":
            guard let name, let version, let day, let days else { return nil }
            return say("\(name) \(version) was published on \(day), less than \(days) days ago")
        case "package_too_new_older":
            guard let name, let version, let day, let days, let newest else { return nil }
            return say("\(name) \(version) was published on \(day), less than \(days) days ago; the newest version that is older is \(newest)")
        case "package_none_old":
            guard let name, let days else { return nil }
            return say("\(name) has no release that is at least \(days) days old")
        case "mcp_registry_away":
            return say("the MCP Registry cannot be reached now")
        case "mcp_registry_no_list":
            return say("the MCP Registry gave no list of servers")
        case "mcp_no_endpoints":
            guard let server, let reason else { return nil }
            return say("the MCP server \(server) gave no OAuth endpoints: \(reason)")
        // **A server named door** (UI-API.md 1.188). No app calls the join route, so no screen shows this line today; it
        // has its case so that no code waits for ever.
        case "server_name_kept":
            guard let name else { return nil }
            return say("This server is called \(name) in Tailscale, and Fleet keeps that name for itself. Rename this server in Tailscale, then run the line again.")
        // **The sealed Google file** (UI-API.md 1.202).
        case "google_file_key":
            return say("the hub cannot read the key of its Google file now")
        case "google_file_lost":
            return say("the Google file of the hub does not open with its key: connect each Google account again")
        // **Telegram's people and token** (UI-API.md 1.243).
        case "no_such_person":
            return say("no such person")
        case "person_blocked":
            return say("you blocked this person")
        case "person_handles_most":
            guard let most else { return nil }
            return say("a person has at most \(most) handles")
        case "agent_no_telegram_bot":
            guard let agent else { return nil }
            return say("\(agent) has no Telegram bot")
        case "bot_name_unknown":
            return say("the bot has not said its name yet: try again when the bot is connected")
        case "token_bot_account":
            return say("a token is for a Discord or Telegram account")
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
