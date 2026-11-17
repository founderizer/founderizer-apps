import Foundation
import Testing
@testable import FleetCore

/// The key swap's own step on each Linux server (`KeySwapPlan`, Part B, app patch 2): the table, the order of the
/// roll-out, the events that give a server its step, the tries (C3), the hold of a put-back over every switch to on, the
/// reading alone with no list of keys, the two steps' texts and the reading of their answers. Example names only.
struct KeySwapPlanTests {
    static let now = 1_763_000_000.0
    static let fleet = "0f1e2d3c4b5a6978"
    static let keyA = Data([0x04] + [UInt8](repeating: 0x11, count: 64)).base64EncodedString()
    static let keyB = Data([0x04] + [UInt8](repeating: 0x22, count: 64)).base64EncodedString()
    static let programA = String(repeating: "a", count: 64)
    static let programB = String(repeating: "b", count: 64)
    static let central = KeySwapCentral(ownerKeys: [keyA], fleet: fleet)!

    static func row(_ name: String, kind: String? = "linux", joined: Bool = true, hub: Bool = false,
                    agents: [String] = [], word: Bool? = false, wish: KeySwapWish? = nil, waits: [KeySwapWait]? = [],
                    readAt: Double? = nil) -> KeySwapServer {
        KeySwapServer(name: name, kind: kind, joined: joined, hub: hub, agents: agents, word: word, wish: wish,
                      waits: waits, readAt: readAt)
    }

    /// A record of a server that this Mac stepped on before, with the keys and the fleet in it.
    static func done(program: String = programA, at: Double = now - 86400) -> KeySwapRecord {
        KeySwapRecord(program: program, keys: [keyA], fleet: fleet, at: at)
    }

    static let waiting = [KeySwapWait(agent: "support", keys: ["SHOP_API_KEY"])]

    // MARK: the table

    @Test func theTableGivesEachRowItsSwitch() {
        // no wish: on where nothing waits, and the item where an agent reads a key that has a site
        #expect(KeySwapPlan.wanted(Self.row("box"), central: true) == KeySwapWanted(switchTo: .on, waitsForTheOwner: false))
        #expect(KeySwapPlan.wanted(Self.row("box", waits: Self.waiting), central: true)
                == KeySwapWanted(switchTo: nil, waitsForTheOwner: true))
        // a server that swaps already: nothing to switch, and nothing waits for the owner
        #expect(KeySwapPlan.wanted(Self.row("box", word: true, waits: Self.waiting), central: true)
                == KeySwapWanted(switchTo: nil, waitsForTheOwner: false))
        // the owner's wish wins over the waits
        #expect(KeySwapPlan.wanted(Self.row("box", wish: .on, waits: Self.waiting), central: true)?.switchTo == .on)
        #expect(KeySwapPlan.wanted(Self.row("box", word: true, wish: .off), central: true)?.switchTo == .off)
        #expect(KeySwapPlan.wanted(Self.row("box", wish: .off), central: true) == KeySwapWanted(switchTo: nil, waitsForTheOwner: false))
        // waits that the app cannot read: the reading only
        #expect(KeySwapPlan.wanted(Self.row("box", waits: nil), central: true)?.switchTo == nil)
    }

    @Test func noListOfKeysIsTheReadingAloneAndNoSwitch() {
        for row in [Self.row("box"), Self.row("box", wish: .on), Self.row("box", word: true, wish: .off)] {
            #expect(KeySwapPlan.wanted(row, central: false)?.switchTo == nil)
        }
        let step = KeySwapPlan.next([Self.row("box")], facts: KeySwapFacts(central: nil, now: Self.now))
        #expect(step == KeySwapStep(server: "box", keys: [], fleet: nil, then: nil))
        // a server with its reading and nothing but a switch to want gets no step without the list
        let read = Self.row("box", readAt: Self.now - 60)
        #expect(KeySwapPlan.next([read], facts: KeySwapFacts(central: nil, records: ["box": Self.done()], now: Self.now)) == nil)
    }

    @Test func aRowThatGetsNoStep() {
        // the names that are not a server's name too: a hub that is broken into cannot make this Mac's record grow
        let rows = [Self.row("mac-1", kind: "mac"), Self.row("new-1", joined: false), Self.row("hub-1", kind: nil, joined: false, hub: true),
                    Self.row("old-1", word: nil), Self.row("gone-1"), Self.row("two words"), Self.row("-dash"),
                    Self.row(String(repeating: "a", count: 65)), Self.row("")]
        for row in rows {
            #expect(KeySwapPlan.wanted(row, central: true, removed: ["gone-1"]) == nil)
        }
        #expect(KeySwapPlan.next(rows, facts: KeySwapFacts(central: Self.central, removed: ["gone-1"], now: Self.now)) == nil)
    }

    // MARK: the order and the events

    @Test func theRollOutBeginsWithNoAgentThenFewestThenByName() {
        let rows = [Self.row("app-2", agents: ["a", "b"]), Self.row("app-9", agents: ["c"]), Self.row("app-5", agents: ["d"]),
                    Self.row("spare-1")]
        #expect(KeySwapPlan.order(rows).map(\.name) == ["spare-1", "app-5", "app-9", "app-2"])
        let step = KeySwapPlan.next(rows, facts: KeySwapFacts(central: Self.central, now: Self.now))
        #expect(step == KeySwapStep(server: "spare-1", keys: [Self.keyA], fleet: Self.fleet, then: .on))
    }

    @Test func eachEventGivesAServerItsStepAndNothingElseDoes() {
        let quiet = Self.row("box", word: true, readAt: Self.now - 60)
        let facts = KeySwapFacts(central: Self.central, hubProgram: Self.programA, records: ["box": Self.done()], now: Self.now)
        #expect(KeySwapPlan.next([quiet], facts: facts) == nil)                         // nothing to do
        #expect(KeySwapPlan.next([Self.row("box", word: true)], facts: facts)                // no reading on record
                == KeySwapStep(server: "box", keys: [Self.keyA], fleet: Self.fleet, then: nil))
        var more = facts
        more.central = KeySwapCentral(ownerKeys: [Self.keyA, Self.keyB], fleet: Self.fleet)   // a second Mac's key
        #expect(KeySwapPlan.next([quiet], facts: more) == KeySwapStep(server: "box", keys: [Self.keyA, Self.keyB],
                                                                     fleet: Self.fleet, then: nil))
        var release = facts
        release.hubProgram = Self.programB                                              // a release with another vault.py
        #expect(KeySwapPlan.next([quiet], facts: release)?.server == "box")
        release.records["box"]?.at = Self.now - 60                                      // looked a minute ago: at most once in `wait`
        #expect(KeySwapPlan.next([quiet], facts: release) == nil)
        var resign = facts
        resign.resignDue = ["box"]                                                      // the pin's weekly re-sign
        #expect(KeySwapPlan.next([quiet], facts: resign)?.server == "box")
        // the table wants a switch that the word does not say
        #expect(KeySwapPlan.next([Self.row("box", wish: .on, readAt: Self.now - 60)], facts: facts)?.then == .on)
    }

    // MARK: the tries, the lock and the hold

    @Test func aServerThatFailedWaitsItsTriesAndTheNextOneGoesOn() {
        let rows = [Self.row("app-1", agents: ["a"]), Self.row("spare-1")]
        let failed = KeySwapRecord(tries: KeySwapTries(failures: 1, last: Self.now - 300, reason: "No SSH."))
        var facts = KeySwapFacts(central: Self.central, records: ["spare-1": failed], now: Self.now)
        #expect(KeySwapPlan.next(rows, facts: facts)?.server == "app-1")               // a try that changed nothing: on
        facts.now = Self.now + 300                                                       // 10 minutes after the try
        #expect(KeySwapPlan.next(rows, facts: facts)?.server == "spare-1")
        let six = KeySwapRecord(tries: KeySwapTries(failures: 6, last: Self.now, reason: "No SSH."))
        #expect(six.tries?.givenUp == true)
        #expect(six.tries?.isDue(at: Self.now + 1200) == false)                         // then each hour, for ever
        #expect(six.tries?.isDue(at: Self.now + 3600) == true)
    }

    @Test func theLockCountsNoTryAndSendsTheServerAfterTheOthers() {
        let locked = KeySwapPlan.record(KeySwapAnswer(program: Self.programA, outcome: .stopped(
            reason: "Another step changes this machine's vault now, so this one changed nothing.", undone: false), serverWords: nil),
            after: nil, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(locked.tries == nil && locked.lockedAt == Self.now)
        let rows = [Self.row("spare-1"), Self.row("app-1", agents: ["a"])]
        var facts = KeySwapFacts(central: Self.central, records: ["spare-1": locked], now: Self.now + 5)
        #expect(KeySwapPlan.next(rows, facts: facts)?.server == "app-1")
        facts.records["app-1"] = Self.done()                                           // the other is done: the locked one again
        #expect(KeySwapPlan.next([Self.row("spare-1"), Self.row("app-1", agents: ["a"], word: true, readAt: Self.now)],
                                 facts: facts)?.server == "spare-1")
    }

    @Test func aPutBackHoldsEachSwitchToOnOnEveryServer() {
        let putBack = KeySwapAnswer(program: Self.programA, outcome: .stopped(
            reason: "The vault's proxy of this machine is inactive. So this step put the configuration back as it was.",
            undone: true), serverWords: nil)
        let held = KeySwapPlan.record(putBack, after: Self.done(), wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(held.hold == KeySwapHold(program: Self.programA, wish: nil, reason: held.hold!.reason, at: Self.now))
        #expect(held.tries?.failures == 1)
        #expect(KeySwapPlan.showsAtOnce(putBack))
        let rows = [Self.row("spare-1", readAt: Self.now), Self.row("app-1", agents: ["a"]),
                    Self.row("app-2", agents: ["a", "b"], word: true, wish: .off, readAt: Self.now)]
        let facts = KeySwapFacts(central: Self.central, records: ["spare-1": held, "app-2": Self.done()], now: Self.now + 7200)
        // the held server and the next one get no switch to on; the reading still runs where it is due
        #expect(KeySwapPlan.next(rows, facts: facts) == KeySwapStep(server: "app-1", keys: [Self.keyA], fleet: Self.fleet, then: nil))
        // a switch to off, which the owner wished, goes on
        var others = facts
        others.records["app-1"] = Self.done()
        let readApp1 = [rows[0], Self.row("app-1", agents: ["a"], readAt: Self.now), rows[2]]
        #expect(KeySwapPlan.next(readApp1, facts: others)?.then == .off)
        // the hold ends at a new program on that server, at a change of the wish, and at Try again
        #expect(KeySwapPlan.holds(rows[0], held))
        #expect(!KeySwapPlan.holds(Self.row("spare-1", wish: .on), held))
        let newer = KeySwapPlan.record(KeySwapAnswer(program: Self.programB, outcome: .done(state: "there", swaps: false,
            ownerKeys: 1, fleet: true), serverWords: nil), after: held, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(newer.hold == nil && newer.tries == nil)
        var state = KeySwapState()
        state.set(held, server: "spare-1", fleet: Self.fleet)
        state.tryAgain(server: "spare-1", fleet: Self.fleet)
        #expect(state.records(fleet: Self.fleet)["spare-1"]?.hold == nil)
        #expect(state.records(fleet: Self.fleet)["spare-1"]?.tries == nil)
    }

    /// This Mac's records, or the record of the removed servers, that are not known (`RecordKeeper.known`): a put-back's
    /// hold, the tries or a mark can stand in them, so no step runs, not even a reading or a switch to off.
    @Test func recordsThatAreNotKnownHoldEveryStep() {
        let rows = [Self.row("spare-1"), Self.row("app-2", agents: ["a", "b"], word: true, wish: .off, readAt: Self.now)]
        let facts = KeySwapFacts(central: Self.central, records: ["app-2": Self.done()], now: Self.now)
        #expect(KeySwapPlan.next(rows, facts: facts) == KeySwapStep(server: "spare-1", keys: [Self.keyA], fleet: Self.fleet, then: .on))
        // spare-1 swaps already and has its reading: the next step is app-2's switch to off, which the owner wished
        let swapped = [Self.row("spare-1", word: true, readAt: Self.now), rows[1]]
        var read = facts
        read.records["spare-1"] = Self.done()
        #expect(KeySwapPlan.next(swapped, facts: read)?.then == .off)
        for known in [(records: false, removed: true), (records: true, removed: false), (records: false, removed: false)] {
            var unknown = facts
            unknown.recordsKnown = known.records
            unknown.removedKnown = known.removed
            #expect(KeySwapPlan.next(rows, facts: unknown) == nil)
            unknown.records["spare-1"] = Self.done()
            #expect(KeySwapPlan.next(swapped, facts: unknown) == nil)
        }
    }

    /// A stop's words in the record are at most 2000 characters, as a server's own reason is (`KeySwapAnswer.read`).
    @Test func aStopsWordsAreCutTo2000Characters() throws {
        let record = KeySwapPlan.record(stop: String(repeating: "x", count: 5000), after: nil, at: Self.now)
        let reason = try #require(record.tries?.reason)
        #expect(reason.contains(String(repeating: "x", count: 2000)) && !reason.contains(String(repeating: "x", count: 2001)))
        #expect(KeySwapPlan.wanted(Self.row(String(repeating: "a", count: 64)), central: true) != nil)   // the longest name
    }

    @Test func aLateFaultOnAServerThatSwappedShowsAtOnceAndHoldsNobody() {
        let kept = KeySwapAnswer(program: Self.programA, outcome: .stopped(reason: "The vault's proxy of this machine is failed 3 "
            + "seconds after its start. The configuration keeps the part, which it had before this step, so a key that has a "
            + "site is not given to a session until this is repaired.", undone: false), serverWords: nil)
        #expect(KeySwapPlan.showsAtOnce(kept))
        let record = KeySwapPlan.record(kept, after: Self.done(), wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(record.hold == nil && record.tries?.failures == 1)
        let refused = KeySwapAnswer(program: Self.programA, outcome: .stopped(reason: "On this machine each user can listen on "
            + "port 876, so nothing changed.", undone: false), serverWords: nil)
        #expect(!KeySwapPlan.showsAtOnce(refused))
    }

    // MARK: what the answers do

    @Test func aGoodAnswerEndsTheTriesAndKeepsTheKeysThatItHolds() {
        let good = KeySwapAnswer(program: Self.programA, outcome: .done(state: "made", swaps: false, ownerKeys: 2, fleet: true),
                                 serverWords: nil)
        let earlier = KeySwapRecord(tries: KeySwapTries(failures: 3, last: Self.now - 600, reason: "x"))
        let record = KeySwapPlan.record(good, after: earlier, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(record == KeySwapRecord(program: Self.programA, keys: [Self.keyA], fleet: Self.fleet, at: Self.now))
        #expect(KeySwapPlan.switchMayFollow(good, central: Self.central))
        let short = KeySwapAnswer(program: nil, outcome: .done(state: "there", swaps: false, ownerKeys: 0, fleet: false), serverWords: nil)
        #expect(!KeySwapPlan.switchMayFollow(short, central: Self.central))
        #expect(!KeySwapPlan.switchMayFollow(good, central: nil))
        let older = KeySwapPlan.record(KeySwapAnswer(program: nil, outcome: .olderProgram, serverWords: nil), after: nil, wish: nil,
                                       keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(older.tries?.failures == 1 && older.keys == nil)
    }

    // MARK: the steps' texts and their answers

    @Test func theTwoStepsTexts() {
        #expect(KeySwapRemote.keys([Self.keyA], fleet: Self.fleet)
                == "sha256sum /usr/local/lib/fleet-vault/vault.py; python3 -I /usr/local/lib/fleet-vault/vault.py configure "
                + "--swap keep --add-owner-key '\(Self.keyA)' --fleet '\(Self.fleet)'")
        #expect(KeySwapRemote.keys([], fleet: nil)
                == "sha256sum /usr/local/lib/fleet-vault/vault.py; python3 -I /usr/local/lib/fleet-vault/vault.py configure --swap keep")
        #expect(KeySwapRemote.keys([Self.keyA], fleet: nil) == nil)
        #expect(KeySwapRemote.keys([], fleet: Self.fleet) == nil)
        #expect(KeySwapRemote.keys(["bm90IGEga2V5"], fleet: Self.fleet) == nil)
        #expect(KeySwapRemote.keys([Self.keyA], fleet: "not-a-fleet") == nil)
        #expect(KeySwapRemote.turn(.on)
                == "sha256sum /usr/local/lib/fleet-vault/vault.py; python3 -I /usr/local/lib/fleet-vault/vault.py configure --swap on")
        #expect(KeySwapRemote.turn(.off)
                == "sha256sum /usr/local/lib/fleet-vault/vault.py; python3 -I /usr/local/lib/fleet-vault/vault.py configure --swap off")
        #expect(KeySwapCentral(ownerKeys: [], fleet: Self.fleet) == nil)
        #expect(KeySwapCentral(ownerKeys: [Self.keyA], fleet: "x") == nil)
    }

    @Test func theAnswersAreReadFromTheirLastLine() {
        let made = KeySwapAnswer.read("\(Self.programA)  /usr/local/lib/fleet-vault/vault.py\nsome line\n"
            + #"{"ok": true, "state": "made", "swaps": true, "swaps_from": "x", "owner_keys": 1, "fleet": true, "changed": []}"#)
        #expect(made == KeySwapAnswer(program: Self.programA, outcome: .done(state: "made", swaps: true, ownerKeys: 1,
                                                                             fleet: true), serverWords: nil))
        let back = KeySwapAnswer.read(#"{"ok": false, "reason": "So this step put the configuration back.", "undone": true}"#)
        #expect(back.outcome == .stopped(reason: "So this step put the configuration back.", undone: true) && back.program == nil)
        let refused = KeySwapAnswer.read(#"{"ok": false, "reason": "No broker."}"#)
        #expect(refused.outcome == .stopped(reason: "No broker.", undone: false))
        let older = KeySwapAnswer.read("usage: vault.py [-h] ...\nvault.py: error: argument cmd: invalid choice: 'configure' (choose from ...)")
        #expect(older.outcome == .olderProgram)
        let none = KeySwapAnswer.read("ssh: connect to host 100.80.1.3 port 22: Operation timed out")
        #expect(none.outcome == .unread && none.serverWords == "ssh: connect to host 100.80.1.3 port 22: Operation timed out")
        #expect(KeySwapAnswer.read(#"{"ok": true, "state": "made"}"#).outcome == .unread)    // a line with no reading in it
        // never an empty reason: the connection's last line, else its exit status
        #expect(KeySwapAnswer.read("", status: 255).serverWords == "exit status 255")
        #expect(KeySwapAnswer.read("\n  \n", status: 1).serverWords == "exit status 1")
        #expect(KeySwapAnswer.read(#"{"ok": false, "reason": " "}"#, status: 1).outcome
                == .stopped(reason: "exit status 1", undone: false))
        #expect(KeySwapWords.notSwitchedOn("") == "The key swap is not switched on: no output.")
    }

    /// The lines that `vault.py configure` prints, from the one file of both languages: test_key_swap.AnswerLines
    /// makes each one with the real configure and holds this file to them (the manager's read of 16 November: the
    /// app's first reader took `fleet` for the fleet's ID, and the real program prints a boolean).
    @Test func theRealLinesOfConfigureAreReadAsTheAppNeedsThem() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("key-swap-answers.json")
        let read = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let lines = try #require(read["answers"] as? [String: String])
        func answer(_ name: String) throws -> KeySwapAnswer { KeySwapAnswer.read(try #require(lines[name]), status: 0) }
        let made = try answer("made"), there = try answer("there")
        #expect(made.outcome == .done(state: "made", swaps: true, ownerKeys: 1, fleet: true))
        #expect(there.outcome == .done(state: "there", swaps: true, ownerKeys: 1, fleet: true))
        #expect(KeySwapPlan.switchMayFollow(made, central: Self.central))
        let kept = KeySwapPlan.record(made, after: nil, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(kept.keys == [Self.keyA] && kept.fleet == Self.fleet)                // so no keys step comes again
        let refused = try answer("refused"), back = try answer("put back"), part = try answer("kept part")
        guard case .stopped(_, false) = refused.outcome, case .stopped(_, true) = back.outcome,
              case .stopped(_, false) = part.outcome else {
            Issue.record("\(refused) \(back) \(part)")
            return
        }
        #expect(!KeySwapPlan.showsAtOnce(refused) && KeySwapPlan.showsAtOnce(back) && KeySwapPlan.showsAtOnce(part))
        let locked = KeySwapPlan.record(try answer("lock"), after: nil, wish: nil, keys: [], fleet: nil, at: Self.now)
        #expect(locked.lockedAt == Self.now && locked.tries == nil)               // the lock's words, found by their start
    }

    @Test func theReasonIsOneLineThatTheHubTakes() {
        #expect(KeySwapPlan.hubReason(nil) == nil)
        #expect(KeySwapPlan.hubReason("  \n ") == nil)
        #expect(KeySwapPlan.hubReason("one\ntwo  three") == "one two three")
        let long = String(repeating: "word ", count: 100)
        let cut = KeySwapPlan.hubReason(long)!
        #expect(cut.unicodeScalars.count <= KeySwapAnswer.hubLimit && cut.hasSuffix("…") && !cut.contains("\n"))
    }

    // MARK: the rows and the record on the disk

    @Test func aRowThatCannotBeReadLosesItsFactsAndNeverTheList() throws {
        let json = #"""
            {"servers": [
              {"name": "box", "kind": "linux", "joined": true, "hub": false, "agents": ["support"], "key_swap": false,
               "key_swap_wish": null, "key_swap_waits": [{"agent": "support", "keys": ["SHOP_API_KEY"]}],
               "key_swap_reason": null, "key_swap_read_at": 1763000000.5, "address": "100.80.1.3"},
              {"name": "odd", "kind": "linux", "joined": true, "hub": false, "agents": [], "key_swap": "yes",
               "key_swap_wish": "maybe", "key_swap_waits": [{"agent": "support"}]},
              {"name": "older", "kind": "linux", "joined": true, "agents": []}]}
            """#
        let rows = try JSONDecoder().decode(KeySwapRows.self, from: Data(json.utf8)).servers
        #expect(rows.count == 3)
        #expect(rows[0] == Self.row("box", agents: ["support"], waits: Self.waiting, readAt: 1_763_000_000.5))
        #expect(rows[1].word == nil && rows[1].wish == nil && rows[1].waits == nil)
        #expect(KeySwapPlan.wanted(rows[1], central: true) == nil && KeySwapPlan.wanted(rows[2], central: true) == nil)
    }

    // MARK: the rows and their words (the owner's yes of C47)

    @Test func theThreeSentencesAreTheOwnersWithOneFullStop() {
        #expect(KeySwapWords.notSwitchedOn("The vault broker of this machine did not stay up.")
                == "The key swap is not switched on: The vault broker of this machine did not stay up.")
        #expect(KeySwapWords.notSwitchedOn("no line") == "The key swap is not switched on: no line.")
        #expect(KeySwapWords.olderProgram
                == "This server's vault program is older than the hub's release. The server brings it up to date by itself.")
        #expect(KeySwapWords.centralBehind("The install on hub stopped: no clone.")
                == "The central vault does not run the program of the hub's release yet: The install on hub stopped: no clone.")
    }

    @Test func eachStopKeepsItsRowsWordsAndTheRowShowsAfterSixOrAtOnce() {
        let refused = KeySwapAnswer(program: Self.programA, outcome: .stopped(reason: "No broker of its own.", undone: false),
                                    serverWords: nil)
        var record: KeySwapRecord? = nil
        for _ in 0..<5 {
            record = KeySwapPlan.record(refused, after: record, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
            #expect(KeySwapPlan.rowReason(record) == nil)                               // no row before six
        }
        record = KeySwapPlan.record(refused, after: record, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(KeySwapPlan.rowReason(record) == "The key swap is not switched on: No broker of its own.")
        let back = KeySwapAnswer(program: Self.programA, outcome: .stopped(reason: "So this step put the configuration back.",
                                                                          undone: true), serverWords: nil)
        let once = KeySwapPlan.record(back, after: nil, wish: nil, keys: [Self.keyA], fleet: Self.fleet, at: Self.now)
        #expect(KeySwapPlan.rowReason(once) == "The key swap is not switched on: So this step put the configuration back.")
        var state = KeySwapState()
        state.set(once, server: "box", fleet: Self.fleet)
        state.tryAgain(server: "box", fleet: Self.fleet)
        #expect(KeySwapPlan.rowReason(state.records(fleet: Self.fleet)["box"]) == nil)
        let older = KeySwapPlan.record(KeySwapAnswer(program: nil, outcome: .olderProgram, serverWords: nil), after: nil,
                                       wish: nil, keys: [], fleet: nil, at: Self.now)
        #expect(older.tries?.reason == KeySwapWords.olderProgram)
        let unread = KeySwapPlan.record(KeySwapAnswer(program: nil, outcome: .unread, serverWords: "Connection refused"),
                                        after: nil, wish: nil, keys: [], fleet: nil, at: Self.now)
        #expect(unread.tries?.reason == "The key swap is not switched on: Connection refused.")
        let stopped = KeySwapPlan.record(stop: "The fleet has no SSH connection to box on record. Record one on its page in "
                                         + "Servers.", after: nil, at: Self.now)
        #expect(stopped.tries?.reason == "The key swap is not switched on: The fleet has no SSH connection to box on record. "
                + "Record one on its page in Servers.")
        // a good step after them ends the row
        let good = KeySwapPlan.record(KeySwapAnswer(program: Self.programA, outcome: .done(state: "there", swaps: true,
            ownerKeys: 1, fleet: true), serverWords: nil), after: once, wish: nil, keys: [Self.keyA], fleet: Self.fleet,
            at: Self.now)
        #expect(KeySwapPlan.rowReason(good) == nil && good.atOnce == nil)
    }

    @Test func theRowsAreInTheHubsOrderAndNeverForARemovedServer() {
        let six = KeySwapRecord(tries: KeySwapTries(failures: 6, last: Self.now, reason: KeySwapWords.olderProgram))
        let rows = [Self.row("app-2"), Self.row("app-1"), Self.row("gone-1")]
        let needs = KeySwapPlan.needs(rows, records: ["app-1": six, "app-2": six, "gone-1": six], removed: ["gone-1"])
        #expect(needs == [VaultServerNeed(machine: "app-2", reason: KeySwapWords.olderProgram),
                          VaultServerNeed(machine: "app-1", reason: KeySwapWords.olderProgram)])
        #expect(KeySwapPlan.needs(rows, records: [:], removed: []).isEmpty)
    }

    @Test func theOwnerKeysAreReadFromTheCentralVaultsOwnFile() {
        #expect(KeySwapRemote.central.contains("/etc/fleet-vault-central/vault.json"))
        #expect(KeySwapRemote.central.hasPrefix("python3 -I -c '"))
        let line = #"{"owner_keys": ["\#(Self.keyA)"], "fleet": "0f1e2d3c4b5a6978"}"#
        #expect(KeySwapRemote.central(in: "a line before\n" + line) == Self.central)
        #expect(KeySwapRemote.central(in: #"{"owner_keys": [], "fleet": "0f1e2d3c4b5a6978"}"#) == nil)
        #expect(KeySwapRemote.central(in: "Permission denied") == nil)
    }

    @Test func theUpdatesTriesLiveInTheSameFileAndAnOlderFileStillLoads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("key-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("key-swap.json")
        var state = KeySwapState()
        let update = KeySwapUpdate(program: Self.programB, tries: KeySwapTries(failures: 2, last: Self.now, reason: "x"))
        state.setUpdate(update, fleet: Self.fleet)
        try state.save(file)
        #expect(KeySwapState.load(file).update(fleet: Self.fleet) == update)
        try Data(#"{"fleets": {}}"#.utf8).write(to: file)                              // a file with no updates yet
        #expect(KeySwapState.load(file) == KeySwapState())
    }

    @Test func theRecordsLiveOnTheDiskByFleetAndServer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("key-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("key-swap.json")
        #expect(KeySwapState.load(file) == KeySwapState())                              // a new Mac's: none
        var state = KeySwapState()
        state.set(Self.done(), server: "box", fleet: Self.fleet)
        try state.save(file)
        #expect(KeySwapState.load(file).records(fleet: Self.fleet)["box"] == Self.done())
        state.set(nil, server: "box", fleet: Self.fleet)
        #expect(state.fleets.isEmpty)
    }
}
