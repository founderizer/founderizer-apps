import Foundation
import Testing
@testable import FleetCore

/// Synthetic values only. No test names a real secret, agent or account.
private let agents = ["support", "shop-dev", "writer", "tester", "builder"]

private func key(_ env: String, note: String? = nil, grants: [String: String] = [:]) -> TeamLogin {
    TeamLogin(title: env, protected: true, kind: "api_key", env: env, grants: grants, note: note, note_by: note == nil ? nil : "owner")
}

private func item(_ reference: String, _ entry: TeamLogin, listed: [String] = []) -> SecretsList.Item {
    SecretsList.Item(reference: reference, entry: entry,
                     holders: SecretsList.holders(of: reference, entry, agents: agents, listed: [reference: listed]))
}

struct SecretsListTests {
    /// **A profile that lists a secret makes its agent a holder, as a grant does, in the hub's order.** The bug: the
    /// row counts only grants, so a secret that a profile lists says "No agent", shows no face, and Delete sends its
    /// removal, which the hub refuses and which stops the work.
    @Test func aGrantAndAProfileThatListsTheSecretBothMakeAHolder() {
        let entry = key("SHOP_KEY", grants: ["writer": "read", "support": "use"])
        #expect(SecretsList.holders(of: "bws://a", entry, agents: agents, listed: ["bws://a": ["builder", "support"]])
                == ["support", "writer", "builder"])
        // Profiles that were not read count for nothing; a profile that lists another reference neither.
        #expect(SecretsList.holders(of: "bws://a", entry, agents: agents, listed: nil) == ["support", "writer"])
        #expect(SecretsList.holders(of: "bws://a", key("FREE_KEY"), agents: agents, listed: ["bws://b": ["tester"]]).isEmpty)
    }

    /// **Each word of the filter stands in the name or in the note, case and accents folded.** The bugs: a filter that
    /// compares the whole phrase as one piece ("stripe live" misses STRIPE_LIVE_KEY), that reads the name alone (the
    /// owner: "the text filter also finds notes"), or that tells "credito" from "Crédito".
    @Test func eachWordOfTheFilterStandsInTheNameOrTheNote() {
        let live = key("STRIPE_LIVE_KEY", note: "Cuenta de crédito de la tienda")
        #expect(SecretsList.matches(live, words: "stripe live"))
        #expect(SecretsList.matches(live, words: "  CREDITO  "))            // case and accents, and blanks around it
        #expect(SecretsList.matches(live, words: "stripe tienda"))          // one word in the name, one in the note
        #expect(!SecretsList.matches(live, words: "stripe test"))           // every word, not any
        #expect(!SecretsList.matches(key("STRIPE_TEST_KEY"), words: "tienda"))
        #expect(SecretsList.matches(live, words: ""))
        let login = TeamLogin(title: "shop.example.test · admin@example.test", protected: true)
        #expect(SecretsList.matches(login, words: "Shop.Example admin"))    // a login by its title
    }

    /// **The agent filter shows each secret that at least one ticked agent holds, and with no tick every secret.** The
    /// bugs: a secret must be held by every ticked agent (two ticks show less than one), or a secret of no agent is
    /// hidden while no agent is ticked.
    @Test func theAgentFilterShowsWhatAnyTickedAgentHolds() {
        let items = [item("bws://a", key("A_KEY", grants: ["support": "use"])), item("bws://b", key("B_KEY"), listed: ["writer"]),
                     item("bws://c", key("C_KEY", note: "a shop key"))]
        #expect(SecretsList.shown(items, words: "", agents: []).map(\.reference) == ["bws://a", "bws://b", "bws://c"])
        #expect(SecretsList.shown(items, words: "", agents: ["support", "writer"]).map(\.reference) == ["bws://a", "bws://b"])
        #expect(SecretsList.shown(items, words: "key", agents: ["writer"]).map(\.reference) == ["bws://b"])     // words and agents
        #expect(SecretsList.shown(items, words: "shop", agents: []).map(\.reference) == ["bws://c"])
        // "N of M" only while a filter is on.
        #expect(SecretsList.count(shown: 2, of: 3, filtering: SecretsList.filters(words: "", agents: ["writer"])) == "2 of 3")
        #expect(SecretsList.count(shown: 3, of: 3, filtering: SecretsList.filters(words: "  ", agents: [])) == nil)
    }

    /// **A row draws the first three holders as faces and by name, and "+N" counts the others.** The bugs: "+N" counts
    /// every holder ("+5" for five), the faces are of other agents than the names, or a secret of nobody has no words.
    @Test func aRowNamesThreeHoldersAndCountsTheRest() {
        let label: (String) -> String = { $0.capitalized }
        #expect(SecretsList.holderWords(agents, label: label) == "Support, Shop-Dev, Writer +2")
        #expect(SecretsList.faces(agents).shown == ["support", "shop-dev", "writer"] && SecretsList.faces(agents).more == 2)
        #expect(SecretsList.holderWords(["writer", "tester"], label: label) == "Writer, Tester")
        #expect(SecretsList.faces(["writer", "tester"]).more == 0)
        #expect(SecretsList.holderWords([], label: label) == "No agent" && SecretsList.faces([]).shown.isEmpty)
    }

    /// **The bar acts only on the ticked secrets that the list shows.** The bug: a tick that a new filter hides stays
    /// in the plan, so Delete or Take access reaches a secret that he cannot see.
    @Test func theBarActsOnlyOnTickedSecretsThatTheListShows() {
        let items = [item("bws://a", key("A_KEY")), item("bws://b", key("B_KEY"), listed: ["writer"]), item("bws://c", key("C_KEY"))]
        #expect(SecretsList.selected(items, ticked: ["bws://a", "bws://b"], words: "b_key", agents: []).map(\.reference) == ["bws://b"])
        #expect(SecretsList.removal(SecretsList.selected(items, ticked: ["bws://a"], words: "b_key", agents: [])).removes.isEmpty)
        #expect(SecretsList.selected(items, ticked: ["bws://a", "bws://b"], words: "", agents: ["writer"]).map(\.reference) == ["bws://b"])
        // In the list's order, whatever the order of the ticks.
        #expect(SecretsList.selected(items, ticked: ["bws://c", "bws://a"], words: "", agents: []).map(\.reference) == ["bws://a", "bws://c"])
    }

    /// **Give goes only to an agent that does not hold the secret, one pair at a time in one fixed order.** The bugs: a
    /// give of `use` to an agent that reads the key takes its read away; a secret that a profile lists gets a grant
    /// beside it; the order follows the set of ticks, so two runs of one change send their calls in two orders.
    @Test func giveSkipsTheHoldersAndKeepsOneOrder() {
        let secrets = [item("bws://a", key("A_KEY", grants: ["writer": "read"])), item("bws://b", key("B_KEY"), listed: ["support"])]
        let pairs = SecretsList.pairs(.give, secrets: secrets, chosen: ["writer", "support", "tester"], agents: agents)
        #expect(pairs == [SecretsList.Pair(reference: "bws://a", agent: "support"), SecretsList.Pair(reference: "bws://a", agent: "tester"),
                          SecretsList.Pair(reference: "bws://b", agent: "writer"), SecretsList.Pair(reference: "bws://b", agent: "tester")])
        // Nothing to give: the button stays dimmed.
        #expect(SecretsList.pairs(.give, secrets: secrets, chosen: ["writer"], agents: agents) == [SecretsList.Pair(reference: "bws://b", agent: "writer")])
        #expect(SecretsList.pairs(.give, secrets: [secrets[0]], chosen: ["writer"], agents: agents).isEmpty)
        #expect(SecretsList.pairs(.give, secrets: secrets, chosen: [], agents: agents).isEmpty)
    }

    /// **Take ends only grants, and Take access offers only the agents with a grant of a ticked secret.** The bugs: a
    /// take-back for an agent that has the secret from its profile, which no grant can end; or a menu that lists that
    /// agent, whose tick then changes nothing.
    @Test func takeEndsOnlyGrants() {
        let secrets = [item("bws://a", key("A_KEY", grants: ["writer": "read", "tester": "use"]), listed: ["support"]),
                       item("bws://b", key("B_KEY", grants: ["tester": "use"]))]
        #expect(SecretsList.takeable(secrets, agents: agents) == ["writer", "tester"])
        #expect(SecretsList.pairs(.take, secrets: secrets, chosen: ["tester", "support", "writer"], agents: agents)
                == [SecretsList.Pair(reference: "bws://a", agent: "writer"), SecretsList.Pair(reference: "bws://a", agent: "tester"),
                    SecretsList.Pair(reference: "bws://b", agent: "tester")])
        #expect(SecretsList.pairs(.delete, secrets: secrets, chosen: ["tester"], agents: agents).isEmpty)
    }

    /// **Delete removes only the ticked secrets that no agent and no profile holds, and keeps the others.** The bug: a
    /// removal of a secret that an agent still uses (the hub refuses it, and the work stops before the free ones), or
    /// a held secret that the bar does not count.
    @Test func deleteRemovesOnlyWhatNobodyHolds() {
        let secrets = [item("bws://a", key("A_KEY")), item("bws://b", key("B_KEY", grants: ["writer": "use"])),
                       item("bws://c", key("C_KEY"), listed: ["support"]), item("bws://d", key("D_KEY"))]
        #expect(SecretsList.removal(secrets) == SecretsList.Removal(removes: ["bws://a", "bws://d"], held: ["bws://b", "bws://c"]))
        #expect(SecretsList.heldWords(2) == "2 secrets stay, because agents have them.")
        #expect(SecretsList.heldWords(1) == "1 secret stays, because an agent has it.")
    }

    /// **The bar's words count what they say.** The bugs: the button counts calls in place of ticked secrets and agents
    /// ("Give 6 secrets" for 3 secrets and 2 agents), it says "to 0 agents" before an agent is ticked, the wait says
    /// "Giving 0 of 6" at its first call or "7 of 6" at its end, or one of anything takes the plural.
    @Test func theBarsWordsCountWhatTheySay() {
        #expect(SecretsList.buttonWords(.give, secrets: 3, agents: 2) == "Give 3 secrets to 2 agents")
        #expect(SecretsList.buttonWords(.give, secrets: 4, agents: 0) == "Give 4 secrets")
        #expect(SecretsList.buttonWords(.take, secrets: 1, agents: 0) == "Take 1 secret")
        #expect(SecretsList.buttonWords(.give, secrets: 1, agents: 1) == "Give 1 secret to 1 agent")
        #expect(SecretsList.buttonWords(.take, secrets: 1, agents: 4) == "Take 1 secret from 4 agents")
        #expect(SecretsList.buttonWords(.take, secrets: 5, agents: 1) == "Take 5 secrets from 1 agent")
        #expect(SecretsList.progress(.give, done: 0, of: 6) == "Giving 1 of 6")
        #expect(SecretsList.progress(.take, done: 5, of: 6) == "Taking 6 of 6")
        #expect(SecretsList.progress(.delete, done: 6, of: 6) == "Deleting 6 of 6")
        #expect(SecretsList.selectedWords(1) == "1 selected" && SecretsList.selectedWords(4) == "4 selected")
        #expect(SecretsList.agentsWords(0) == "All agents" && SecretsList.agentsWords(1) == "1 agent" && SecretsList.agentsWords(3) == "3 agents")
    }

    /// **"Who can use it", closed, is a line for each level that has agents, Uses it first, and no line for no access.**
    /// The bugs: an agent stands in two lines, a read key shows as used, a level with nobody draws an empty line, the
    /// door's grant shows as an agent, a name that the list of agents has two times stops the app, or "+N" names nobody
    /// under the pointer.
    @Test func whoCanUseItClosedIsOneLineForEachLevelThatHasAgents() {
        let access: [String: SecretGrant] = ["writer": .read, "support": .use, "builder": .read, "door": .use]
        let lines = SecretsList.accessLines(access, holders: agents, login: false)
        #expect(lines == [SecretsList.AccessLine(level: .use, agents: ["support"]),
                          SecretsList.AccessLine(level: .read, agents: ["writer", "builder"])])
        // a login is never read: each of its grants is Uses it
        #expect(SecretsList.accessLines(access, holders: agents, login: true)
                == [SecretsList.AccessLine(level: .use, agents: ["support", "writer", "builder"])])
        // nobody has it yet (a new key): no line at all, and the form says "No agent"
        #expect(SecretsList.accessLines([:], holders: agents, login: false).isEmpty)
        #expect(SecretsList.accessLines(["door": .use], holders: agents, login: false).isEmpty)
        // a name two times in the list of agents: one face, and no stop
        #expect(SecretsList.accessLines(access, holders: ["writer", "support", "writer"], login: false)
                == [SecretsList.AccessLine(level: .use, agents: ["support"]), SecretsList.AccessLine(level: .read, agents: ["writer"])])
        // a long line ends in "+N", which stands for the agents after the eighth
        let many = (1...11).map { "agent-\($0)" }
        #expect(SecretsList.lineFaces(many).shown == Array(many.prefix(8)) && SecretsList.lineFaces(many).rest == Array(many.suffix(3)))
        #expect(SecretsList.lineFaces(["support"]).shown == ["support"] && SecretsList.lineFaces(["support"]).rest.isEmpty)
    }

    /// **A card's badge opens the one secret of its name, and a name of two secrets is no badge.** The bug: the badge of
    /// a name that two keys from before have opens one of them, and his new value goes into the key that the request did
    /// not mean.
    @Test func aNameOfTwoSecretsGivesNoBadgeAndNoCard() {
        let one = "bws://11111111-2222-4333-8444-555555555551", two = "bws://11111111-2222-4333-8444-555555555552"
        let three = "bws://11111111-2222-4333-8444-555555555553", shop = "bws://11111111-2222-4333-8444-555555555554"
        // an older key whose title he changed is still known by its variable name
        let renamed = TeamLogin(title: "The old shop key", protected: true, kind: "api_key", env: "SHOP_API_KEY")
        let login = TeamLogin(title: "shop.example.test · admin@example.test", protected: true)
        let catalog = [one: key("SHOP_API_KEY"), two: renamed, three: key("MAIL_API_KEY"), shop: login]
        #expect(SecretsList.reference(named: "SHOP_API_KEY", in: catalog) == nil)
        #expect(SecretsList.reference(named: "MAIL_API_KEY", in: catalog) == three)
        #expect(SecretsList.reference(named: "shop.example.test · admin@example.test", in: catalog) == shop)
        #expect(SecretsList.reference(named: "OTHER_API_KEY", in: catalog) == nil)
        let badges = SecretsList.badges(catalog)
        #expect(badges.map(\.name) == ["MAIL_API_KEY", "shop.example.test · admin@example.test"])
        #expect(badges.map(\.key) == [true, false])
        // the same key alone is a badge again
        #expect(SecretsList.reference(named: "SHOP_API_KEY", in: [one: key("SHOP_API_KEY"), three: key("MAIL_API_KEY")]) == one)
    }
}
