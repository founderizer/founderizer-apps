import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **The role beside a name in a chat's badge is grey and no part of the name's link** (`ChatBadgeText.drawn`; the
/// owner's answer of 23 November 2026: "The name with the role in grey"), as in a card's badge: one link for one name,
/// for the keyboard and VoiceOver (a run with its own colour keeps it with or without a link, as measured on 24 November
/// 2026). The words stay "Atlas · Marketing", **where an agent's words wrote the role and where they wrote the name**
/// (`RoleNames.withRoles`; the owner, 25 November 2026: "I think we agreed that we should show both agent name and
/// role? like in a nice card badge?"). The bug that this catches: the role keeps the name's link (a second link of one
/// name), the role draws in the words' colour, the name loses its link, or a name that the words wrote has no role.
@MainActor @Test func theRoleInAChatsBadgeIsGreyAndNoPartOfTheNamesLink() throws {
    let book = ChatNames(agents: [("atlas", "Marketing")])
    for (said, shown) in [("I asked Marketing.", "I asked Atlas\u{00A0}·\u{00A0}Marketing."),
                          ("Atlas wrote it.", "Atlas\u{00A0}·\u{00A0}Marketing wrote it.")] {
        let words = book.words(AttributedString(said))
        let drawn = ChatBadgeText.drawn(words.text)
        #expect(drawn.runs[\.link].compactMap { $0.0 == nil ? nil : String(drawn[$0.1].characters) } == ["Atlas"], "\(said)")
        #expect(String(drawn.characters) == shown)
        // the chat's text as it draws: the words in red, the link's tint in green, so that only the role can be grey
        let text = ChatBadgeText.text(words, links: false, size: 30).text
        let renderer = ImageRenderer(content: text.font(.system(size: 30)).foregroundStyle(Color(red: 1, green: 0.25, blue: 0.25))
            .tint(Color(red: 0, green: 0.8, blue: 0)).padding(8).background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var grey = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let (r, g, b) = (colour.redComponent, colour.greenComponent, colour.blueComponent)
                if r > 0.3, abs(r - g) < 0.06, abs(g - b) < 0.06 { grey += 1 }
            }
        }
        #expect(grey > 200, "the role's part draws grey: \(grey) grey pixels in \(said)")
    }
}

/// **A chat's book takes the names of the fleet's people from the People page's reading** (`FleetStore.chatNames`,
/// `ChatNames(people:)`; reviews of 26 November 2026): an agent's name that a person on People has, a name or an alias of
/// a person's handle, or a name or an alias of the owner's own handle, keeps its badge in an agent's words and draws no
/// role, because "Mia asked for a refund" can speak of that person. **The live round reads People again while the store
/// has no People reading** (the People page keeps a failed read of its own on the page), but not after a refusal, not
/// after three failed reads and not once it has them (`keepLive`, `readPeopleAgain`). The bugs that these catch: the
/// book is made with no people's names or with no handles' names or aliases, a People read that failed is never read
/// again, or a refused one is read every 15 seconds for the whole session, so the chat shows "Mia · Web Developer asked
/// for a refund", a false thing, or the hub gets a read for nothing.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ChatRolePeopleTests {
    /// The hub's reading: the manager, and five agents with roles.
    static func state(_ database: String, now: Int) throws -> Data {
        let roles = [("mia", "Web Developer"), ("kai", "Marketing"), ("leo", "Web Lead"), ("nova", "Customer Support Lead"),
                     ("iris", "SEO & AI Search")]
        let agents: [[String: Any]] = [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]]
            + roles.map { ["name": $0.0, "role": "worker", "title": $0.1, "runtime": "claude", "can": [], "placed": true] }
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": database, "time": now, "agents": agents, "tasks": [], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
            "ui_features": [People.feature]] as [String: Any])
    }

    /// The People page's reading: a person Mia Example; a person whose handles have the name Kai Sample and the alias
    /// Nova; and the owner's handles, with the alias Leo and the name Iris Sample.
    static func people(_ database: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "db": database, "roles": [],
            "owner": ["handles": [["app": "whatsapp", "id": "15550001111@s.whatsapp.net", "alias": "Leo"],
                                  ["app": "discord", "id": "987654321", "name": "Iris Sample"]]],
            "people": [
                ["id": 1, "name": "Mia Example", "role": "customer", "agents": [], "handles": [], "conversations": []],
                ["id": 2, "name": "Pat Example", "role": "customer", "agents": [], "conversations": [],
                 "handles": [["app": "discord", "handle": "123456789", "name": "Kai Sample"],
                             ["app": "telegram", "handle": "555", "alias": "Nova"]]]]] as [String: Any])
    }

    static let said = ["Mia asked for a refund.", "Kai sent the list.", "Nova answered.", "Leo replied.", "Iris read it."]

    /// A store on a stand-in hub whose reading is `state`, after its first read and its one launch read of People (on
    /// the task board, so no agent's chat reads People too); the hub's People route answers as the test gave it.
    @MainActor static func store(_ hub: LoopbackHub, state: Data, database: String) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        store.destination = .activity
        Task { await store.refresh() }
        guard ViewHost.turn(10, until: { store.state?.db == database && store.lastSuccess != nil }),
              ViewHost.turn(10, until: { Self.peopleReads(hub) == 1 && !store.readsPeople }) else {
            throw ViewHost.Missing(description: "the stand-in hub's reading or the launch's read of People did not come")
        }
        return store
    }

    static func peopleReads(_ hub: LoopbackHub) -> Int { hub.requests.filter { $0.path.hasPrefix("/ui/people") }.count }
    static func healthReads(_ hub: LoopbackHub) -> Int { hub.requests.filter { $0.path.hasPrefix("/ui/health") }.count }
    static let starting: (status: Int, body: Data) = (503, Data(#"{"error":"starting"}"#.utf8))

    @Test func aNameThatAPersonOnPeopleHasDrawsNoRoleInAChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (before: [String], after: [String], badges: Bool) in
            let now = Int(Date().timeIntervalSince1970), database = "people-role-\(UUID().uuidString)"
            let store = ViewHost.store(try HubState.decode(Self.state(database, now: now)))
            let before = Self.said.map { String(store.chatNames.words(AttributedString($0)).text.characters) }
            let people = try JSONDecoder().decode(PeopleSnapshot.self, from: Self.people(database))
            store.keep(PeopleReading<PeopleSnapshot>.current(people, at: Double(now)), as: "people.list.fleet")
            let after = Self.said.map { store.chatNames.words(AttributedString($0)) }
            return (before, after.map { String($0.text.characters) },
                    after.map { $0.badges.map(\.target) } == ["mia", "kai", "nova", "leo", "iris"].map { [.agent($0)] })
        }
        #expect(seen.before == ["Mia\u{00A0}·\u{00A0}Web Developer asked for a refund.",
                                "Kai\u{00A0}·\u{00A0}Marketing sent the list.",
                                "Nova\u{00A0}·\u{00A0}Customer Support Lead answered.",
                                "Leo\u{00A0}·\u{00A0}Web Lead replied.", "Iris\u{00A0}·\u{00A0}SEO & AI Search read it."],
                "with no person, each role shows")
        #expect(seen.after == Self.said, "a person's name, a handle's name and alias, the owner's handle's alias and name")
        #expect(seen.badges, "each name keeps its badge")
        #expect(screen.stayedHis)
    }

    /// The launch's read of People fails, so the store keeps no People reading: People is read again, and the role goes.
    @Test func aPeopleReadThatFailedIsReadAgain() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (failed: String, after: String) in
            let now = Int(Date().timeIntervalSince1970), database = "people-again-\(UUID().uuidString)"
            let state = try Self.state(database, now: now)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            hub.answer("GET", "/ui/people") { _ in Self.starting }
            let store = try Self.store(hub, state: state, database: database)
            let words = AttributedString(Self.said[0])
            let failed = String(store.chatNames.words(words).text.characters)
            hub.give(try Self.people(database), at: "/ui/people")
            ViewHost.turn(10) {
                store.readPeopleAgain()
                return String(store.chatNames.words(words).text.characters) == Self.said[0]
            }
            return (failed, String(store.chatNames.words(words).text.characters))
        }
        #expect(seen.failed == "Mia\u{00A0}·\u{00A0}Web Developer asked for a refund.", "the failed reads leave no names")
        #expect(seen.after == "Mia asked for a refund.", "People is read again")
        #expect(screen.stayedHis)
    }

    /// **A People read that the hub refuses is not read again, and three that fail end the reads again**: after a 503 at
    /// the launch, a 403 (a device or a member of the fleet), a 404 or a 410 (a hub with no such route) to the next read
    /// ends them at once, and three 503s end them too (`peopleFailed`), as three 429s or 408s do (a 429 and a 408 ask
    /// for a later read: a failure, not a refusal). The test asks for the reads again all the time.
    @Test func aRefusedPeopleReadOrThreeFailuresEndTheReadsAgain() async throws {
        let (reads, screen) = try await ViewHost.onMainLoop { () -> [Int] in
            try [403, 404, 410, 503, 429, 408].map { status in
                let now = Int(Date().timeIntervalSince1970), database = "people-end-\(status)-\(UUID().uuidString)"
                let state = try Self.state(database, now: now)
                let hub = try LoopbackHub(state: state)
                defer { hub.stop() }
                hub.answer("GET", "/ui/people") { _ in Self.starting }
                let store = try Self.store(hub, state: state, database: database)
                hub.answer("GET", "/ui/people") { _ in (status, Data(#"{"error":"no"}"#.utf8)) }
                // the reads again that come: one with a refusal, two more failures (three with the launch's)
                let due = [503, 429, 408].contains(status) ? 3 : 2
                guard ViewHost.turn(10, until: {
                    store.readPeopleAgain()
                    return Self.peopleReads(hub) >= due && !store.readsPeople
                }) else {
                    throw ViewHost.Missing(description: "the reads again of People after the launch's 503 did not end")
                }
                // and no more: a read that it starts would be on its way at once
                store.readPeopleAgain()
                return (store.readsPeople ? 1 : 0) + Self.peopleReads(hub) - due
            }
        }
        #expect(reads == [0, 0, 0, 0, 0, 0], "no read of People after a 403, a 404, a 410 or a third failure: \(reads)")
        #expect(screen.stayedHis)
    }

    /// **A failed read of People counts once against its reads again, however many chats joined it, and a failed read
    /// of another shared reading does not count** (`peopleReadFailed`, by the read's mark): after the launch's 503, two
    /// chats' reads of People join one GET that answers 503, and a reading of another feature fails; that is two failures
    /// of three, so the next read again goes out and takes the people. The bugs that this catches: each chat that joined
    /// counts the one GET (a hub that restarts while the app opens two chats ends the reads again before it answers), or
    /// another reading's failure counts against People's, and the chat keeps "Mia · Web Developer" for a person.
    @Test func aFailedReadCountsOnceAgainstThePeopleReadsAgain() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (gets: Int, after: String) in
            let now = Int(Date().timeIntervalSince1970), database = "people-once-\(UUID().uuidString)"
            let state = try Self.state(database, now: now)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            hub.answer("GET", "/ui/people") { _ in Self.starting }
            let store = try Self.store(hub, state: state, database: database)
            // two chats' reads of People: the GET of the first waits until the second joined it, and fails
            let letGo = DispatchSemaphore(value: 0)
            defer { letGo.signal() }        // also when the test fails: the held answer goes, and the hub can stop
            hub.answerApart()
            hub.answer("GET", "/ui/people") { _ in letGo.wait(); return Self.starting }
            let address = store.hub, ended = Ended()
            for agent in ["mia", "kai"] {
                Task {
                    _ = await store.prefetch(PeoplePage.prefetch, agent: agent, hub: address, database: database)
                    ended.count += 1
                }
            }
            // the first chat's GET is out, and the second chat waits for its answer (`readers`)
            let joined = { Self.peopleReads(hub) == 2 && store.readers(of: PeoplePage.peopleName) == 2 }
            guard ViewHost.turn(10, until: joined) else {
                throw ViewHost.Missing(description: "the second chat's read of People did not join the first's")
            }
            letGo.signal()
            // a reading of another feature that all agents share, which fails
            let other = PagePrefetch("other.list.fleet", sharedAcrossAgents: true) { _, _ in throw HubError.invalidResponse }
            Task {
                _ = await store.prefetch(other, agent: "mia", hub: address, database: database)
                ended.count += 1
            }
            guard ViewHost.turn(10, until: { ended.count == 3 && !store.readsPeople }) else {
                throw ViewHost.Missing(description: "the failed reads did not end")
            }
            let gets = Self.peopleReads(hub)
            hub.give(try Self.people(database), at: "/ui/people")
            let words = AttributedString(Self.said[0])
            ViewHost.turn(10) {
                store.readPeopleAgain()
                return String(store.chatNames.words(words).text.characters) == Self.said[0]
            }
            return (gets, String(store.chatNames.words(words).text.characters))
        }
        #expect(seen.gets == 2, "the two chats joined one GET of People: \(seen.gets) with the launch's")
        #expect(seen.after == "Mia asked for a refund.", "two failures of three: People is read again")
        #expect(screen.stayedHis)
    }

    /// **A read again keeps no older answer over a newer one**: the People page keeps an answer while the store's read
    /// again is on its way, and that read's own answer, which comes after, leaves the page's as it is (`prefetch(again:)`).
    /// The bug that this catches: a slow read again writes over the reading that the page kept after it began.
    @Test func aReadAgainKeepsNoOlderAnswerOverANewerOne() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> String in
            let now = Int(Date().timeIntervalSince1970), database = "people-newer-\(UUID().uuidString)"
            let state = try Self.state(database, now: now)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            hub.answer("GET", "/ui/people") { _ in Self.starting }
            let store = try Self.store(hub, state: state, database: database)
            // the read again waits on its own thread until the test lets it answer with the people of before
            let older = try Self.people(database), letGo = DispatchSemaphore(value: 0)
            defer { letGo.signal() }        // also when the test fails: the held answer goes, and the hub can stop
            hub.answerApart()
            hub.answer("GET", "/ui/people") { _ in letGo.wait(); return (200, older) }
            store.readPeopleAgain()
            guard ViewHost.turn(10, until: { Self.peopleReads(hub) == 2 }) else {
                throw ViewHost.Missing(description: "no read again of People")
            }
            // the page's newer answer: nobody of the fleet's is called Mia now
            let newer = try JSONDecoder().decode(PeopleSnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "db": database, "roles": [], "owner": ["handles": []], "people": []] as [String: Any]))
            store.keep(PeopleReading<PeopleSnapshot>.current(newer, at: Double(now)), as: "people.list.fleet")
            letGo.signal()
            guard ViewHost.turn(10, until: { !store.readsPeople }) else {
                throw ViewHost.Missing(description: "the read again did not end")
            }
            return String(store.chatNames.words(AttributedString(Self.said[0])).text.characters)
        }
        #expect(seen == "Mia\u{00A0}·\u{00A0}Web Developer asked for a refund.", "the page's newer answer stays: \(seen)")
        #expect(screen.stayedHis)
    }

    /// **A People read that hangs holds no live round, and no second read of People starts while it is on its way**
    /// (`readPeopleAgain` in a task of its own, with `peopleReading`): the live round reads People again beside it, the
    /// read hangs (the stand-in hub holds it on a thread of its own and answers the rest), and the next round, 15
    /// seconds later, reads the health again and starts no second read of People (`peopleReadsAgain`: the store's reads
    /// of one name join, so the hub's count cannot tell).
    @Test func aPeopleReadThatHangsHoldsNoLiveRound() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 55) { () -> (again: Bool, next: Bool, reads: Int) in
            let now = Int(Date().timeIntervalSince1970), database = "people-hang-\(UUID().uuidString)"
            let state = try Self.state(database, now: now)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            hub.answer("GET", "/ui/people") { _ in Self.starting }
            let store = try Self.store(hub, state: state, database: database)
            hub.hold("GET", "/ui/people")
            let started = store.peopleReadsAgain
            // the first live round, with the read again beside it, which hangs
            store.keepLive(PagePrefetch.live)
            let again = ViewHost.turn(10) { Self.peopleReads(hub) == 2 && Self.healthReads(hub) >= 1 }
            // the next live round, when it is due (15 seconds after the first)
            let health = Self.healthReads(hub)
            let next = ViewHost.turn(20) { store.keepLive(PagePrefetch.live); return Self.healthReads(hub) > health }
            return (again, next, store.peopleReadsAgain - started)
        }
        #expect(seen.again, "the live round reads People again beside its own readings")
        #expect(seen.next, "a People read that hangs holds no next round")
        #expect(seen.reads == 1, "no second read again of People while one is on its way: \(seen.reads) started")
        #expect(screen.stayedHis)
    }
}

/// How many of a test's reads ended: the tasks that read on the main actor count them there.
@MainActor private final class Ended { var count = 0 }
