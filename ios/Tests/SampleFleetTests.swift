import CoreText
import CryptoKit
import FleetCore
import Foundation
import Network
import SwiftUI
import Synchronization
import Testing
import UIKit
import UserNotifications
@testable import FleetMobile

/// The sample fleet (`SampleFleet.swift`): what a phone with no hub can look at, read through the phone's own client
/// as a hub's answers, with every write refused in the hub's words and nothing of it kept.
@Suite("The sample fleet", .serialized)
struct SampleFleetTests {
    private let client = MobileClient(answering: SampleHub.host, with: SampleHub.self)
    private let began = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("reads as a hub answers it, every time in the day before it began and in its order")
    func reads() async throws {
        SampleHub.begin(at: began)
        let read = try #require(try await client.snapshot(at: SampleHub.address, key: nil, database: nil, etag: nil))
        let fleet = read.snapshot
        #expect(fleet.db == SampleHub.database)
        #expect(fleet.time == began.timeIntervalSince1970)
        #expect(fleet.agents.map(\.title) == ["Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing"])
        #expect(fleet.needs.count == 2)
        #expect(fleet.tasks.count == 3 && fleet.recent.count == 3)
        let times = fleet.agents.compactMap { $0.last?.ts } + fleet.needs.map(\.raised)
            + (fleet.tasks + fleet.recent).map(\.created)
        #expect(times.count == 13)
        #expect(times.allSatisfy { $0 <= fleet.time && $0 > fleet.time - 86_400 })
        // A task is asked, then started, then busy or delivered, and none of it after the sample began.
        for task in fleet.tasks {
            let started = try #require(task.started), active = try #require(task.last_activity)
            #expect(task.created <= started && started <= active && active <= fleet.time, "\(task.title)")
        }
        for task in fleet.recent {
            let started = try #require(task.started), delivered = try #require(task.delivered)
            #expect(task.created <= started && started <= delivered && delivered <= fleet.time, "\(task.title)")
        }
        // What would call the network from a sample is not in its features.
        let features = Set(fleet.ui_features ?? [])
        #expect(features.isDisjoint(with: ["push", "sealed_push", "live_changes", "recovery_copy"]))
        #expect(features.isSuperset(of: ["mobile", "direct_chat"]))
        // An unchanged sample answers 304, as an unchanged fleet does.
        #expect(try await client.snapshot(at: SampleHub.address, key: nil, database: fleet.db, etag: read.etag) == nil)
    }

    @Test("has every chat and every task, and nothing after their cursors")
    func pages() async throws {
        SampleHub.begin(at: began)
        let fleet = try #require(try await client.snapshot(at: SampleHub.address, key: nil, database: nil, etag: nil))
            .snapshot
        for agent in fleet.agents {
            let page = try await client.chat(at: SampleHub.address, key: nil, database: fleet.db, agent: agent.name,
                                             since: nil)
            #expect(!page.items.isEmpty, "\(agent.name)")
            #expect(page.cursor == page.items.last?.ts)
            let after = try await client.chat(at: SampleHub.address, key: nil, database: fleet.db, agent: agent.name,
                                              since: page.cursor)
            #expect(after.items.isEmpty && after.cursor == page.cursor)
        }
        for head in fleet.tasks + fleet.recent {
            let page = try await client.task(at: SampleHub.address, key: nil, database: fleet.db, id: head.id, since: 0)
            #expect(page.task.title == head.title)
            let after = try await client.task(at: SampleHub.address, key: nil, database: fleet.db, id: head.id,
                                              since: page.cursor)
            #expect(after.notes.isEmpty && after.cursor == page.cursor)
        }
    }

    @Test("refuses every write in the hub's words")
    func refuses() throws {
        var post = URLRequest(url: SampleHub.address.appendingPathComponent("ui/messages"))
        post.httpMethod = "POST"
        let answer = SampleHub.answer(post)
        #expect(answer.status == 409)
        let response = try #require(HTTPURLResponse(url: post.url!, statusCode: answer.status, httpVersion: nil,
                                                    headerFields: nil))
        do {
            _ = try MobileClient.check(response, data: answer.body)
            Issue.record("a write in the sample was taken")
        } catch let error as MobileError {
            #expect(error.notSentWords == "Not sent: This is a sample.")
            #expect(error.isDefinitive)
        }
        // A route that the sample does not have is not found, as on a hub.
        #expect(SampleHub.answer(URLRequest(url: SampleHub.address.appendingPathComponent("ui/owner/devices"))).status
            == 404)
    }

    /// A phone with no hub reads nothing and says nothing about a hub, and **a typed code goes nowhere** (F7, piece A4):
    /// it went to the built-in address, which names no hub, and after the request's 10 seconds the phone said "Your hub
    /// did not answer. Check that its server is on." about a server that was on. The stand-in of the phone's network
    /// counts each request that would leave it.
    @MainActor @Test("a phone with no hub reads nothing, sends no code, and says nothing about a hub")
    func noHub() async throws {
        try await Self.withoutHub {
            NoHubNetwork.requests.withLock { $0 = 0 }
            let store = MobileStore(client: MobileClient(answering: NoHubNetwork.host, with: NoHubNetwork.self))
            #expect(store.hasNoHub && store.addressText.isEmpty)
            await store.refresh()
            #expect(store.lastRead == nil && store.readError == nil)
            #expect(store.unavailableWords == nil && !store.readsTheHub)
            #expect(store.keyWords == nil && !store.keyIsHeldBack)
            // A whole code, as the field sends it: the phone says where its fleet comes from.
            #expect(await store.enroll(code: "ABCD-2345")
                    == "This phone has no fleet yet. Point its camera at the picture on your Mac.")
            #expect(NoHubNetwork.requests.withLock { $0 } == 0)
        }
    }

    /// **A join that gets no answer says to check Tailscale on this phone** (F7, piece A5): the hub answers only on the
    /// owner's private network, and a phone with Tailscale off said "Check that its server is on." about a server that
    /// was on. A read of the phone's own addresses did not see Tailscale off on the owner's iPhone (his check of 23
    /// November 2026), so every join that gets no answer says the one line. The stand-in of the phone's network
    /// answers nothing, as a hub behind a tunnel that is off.
    @MainActor @Test("a join that gets no answer says to check that Tailscale is on on this phone, in each language")
    func joinWithNoAnswer() async throws {
        try await Self.withoutHub {
            SilentHubNetwork.paths.withLock { $0 = [] }
            UserDefaults.standard.set("http://\(SilentHubNetwork.host):8765", forKey: "hubAddress")
            let store = MobileStore(client: MobileClient(answering: SilentHubNetwork.host, with: SilentHubNetwork.self))
            #expect(!store.hasNoHub)
            #expect(await store.enroll(code: "ABCD-2345", read: false)
                    == "Your hub did not answer. Check that Tailscale is on on this phone.")
            // The code went to the hub, and nothing answered it: not a guard of the phone's that kept it back.
            #expect(SilentHubNetwork.paths.withLock { $0 } == ["/ui/owner/enroll"])
            let spanish = try PhoneSpanish.run { MobileError.enrollWords(.noAnswer) }
            #expect(spanish == "Tu hub no ha respondido. Comprueba que Tailscale esté activado en este teléfono.")
        }
    }

    @MainActor @Test("opens, refuses a message and a file, and leaves nothing of itself behind")
    func store() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            let before = Self.keptState()
            store.startSample()
            store.chatRoute = [.chat("wren")]
            await store.refresh()
            #expect(store.sample && store.hub == SampleHub.address && !store.hasNoHub)
            #expect(store.agents.count == 5 && store.unavailableWords == nil && !store.keyIsHeldBack)
            #expect(store.hasRead(chat: "wren"))
            store.setDraft("Ship it on Monday.", for: "theo")
            store.setAnswerDraft("Refund it", for: 1)
            store.setDraft("Offer the customer a voucher instead.", for: "wren")
            await store.send(to: "wren")
            // The request is marked as refused, and its line is made from the refusal's fields when it is read.
            #expect(store.pending?.refusal != nil && store.pending?.notSentLine == "Not sent: This is a sample.")
            // It was kept as the hub's refusal: its status and its words, the sample's own, and no code.
            #expect(store.pending?.hubRefusal == HubRefusal(status: 409, hubWords: SampleHub.refusal))
            let composer = MobileStore.stageKey(agent: "wren")
            await store.stage(Data("x".utf8), name: "note.txt", mime: "text/plain", for: composer)
            #expect(store.fileError == "Not sent: This is a sample.")
            #expect(store.stagedFiles(for: composer).isEmpty)
            // Nothing of it was written to this phone: drafts, answers, seen marks, files, readings, chats.
            #expect(Self.keptState() == before)
            store.leaveSample()
            #expect(!store.sample && store.hasNoHub && store.pending == nil && store.snapshot == nil)
            #expect(store.draft(for: "theo").isEmpty && store.answerDraft(for: 1).isEmpty)
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)
            #expect(Self.keptState() == before)
        }
    }

    @MainActor @Test("a start after a launch that ended inside the sample finds nothing of it")
    func endedInside() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            store.startSample()
            await store.refresh()
            store.setDraft("Offer the customer a voucher instead.", for: "wren")
            await store.send(to: "wren")
            // The request is marked as refused, and its line is made from the refusal's fields when it is read.
            #expect(store.pending?.refusal != nil && store.pending?.notSentLine == "Not sent: This is a sample.")
            // No Leave: the app ends inside the sample, and starts again.
            let next = MobileStore()
            #expect(next.pending == nil && !next.sample && next.hasNoHub)
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)
        }
    }

    @MainActor @Test("a hub of his own ends the sample, and the sample's address is no hub")
    func connect() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            store.startSample()
            store.addressText = "http://sample.founderizer.invalid"
            await store.connect()
            #expect(store.sample && store.addressError != nil)
            store.addressText = "http://127.0.0.1:9"
            await store.connect()
            #expect(!store.sample && store.hub == URL(string: "http://127.0.0.1:9/"))
        }
    }

    /// **The Mac's code link joins with no line about the phone's key** (`MobileStore.openLink`). A recording on an
    /// iPhone 18 Pro (11 November 2026) showed "The hub wants this phone's key and the phone sent none" over Chats for
    /// the quarter second of the enrolment: the phone read the hub with no key before it had one.
    ///
    /// **A phone with no hub joins also when it holds a key that an earlier install left** (F7, piece A1): iOS keeps a
    /// keychain item when the app is deleted, and after a reinstall each link said "This code is for another hub", so
    /// the phone could join no fleet. The old key goes before the join and never reaches the hub: the enrolment carries
    /// no key, and the read after it carries the new one. **A phone with only the sample fleet open is in no fleet
    /// either** (the A1 validator's finding 1): a new owner looks at the sample first, then points the camera at the
    /// Mac, so the same link joins it the same way.
    @MainActor @Test("the Mac's code link joins a phone with no hub or with only the sample open, also one with a key of an earlier install, and no line about its key shows at any moment",
                     .timeLimit(.minutes(1)), arguments: [false, true])
    func linkJoins(sampleOpen: Bool) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = LinkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own: the key of an enrolled phone is never touched. It holds the key that an
                // earlier install left.
                let holder = DeviceKey(account: "device-key-link-check")
                try holder.remove()
                defer { try? holder.remove() }
                try holder.save("a-key-that-an-earlier-install-left")
                let store = Self.store(holder, named: "device-key-link-check")
                if sampleOpen { store.startSample() }
                #expect((sampleOpen ? store.sample : store.hasNoHub) && store.keyState == .locked)
                store.chatRoute = [.settings, .enroll]
                let link = try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345"))
                let join = Task { await store.openLink(link) }
                // The enrolment is on its way, and the hub holds its answer: the phone is at the hub and says nothing
                // about its key. A phone that did not follow the link has its code for Add this phone, and sent nothing.
                try await Self.until { hub.log.contains { $0.hasPrefix("POST /ui/owner/enroll") } || store.linkedCode != nil }
                #expect(store.linkedCode == nil, "the phone did not follow the link: \(store.linkedCode?.problem ?? "")")
                #expect(store.hub.absoluteString == address + "/" && !store.hasNoHub && !store.sample)
                #expect(store.unavailableWords == nil && store.authProblem == nil && store.readError == nil)
                hub.answerEnrolment()
                await join.value
                // No read went before the key, so the hub had no read to refuse; the enrolment carried no key, and the
                // read after it the new one.
                #expect(hub.log == ["POST /ui/owner/enroll", "GET /ui/mobile with the key"])
                #expect(store.keyState == .ready && store.lastRead != nil && store.snapshot?.db == "gen-link")
                #expect(try holder.pressKey() == LinkHub.key)
                #expect(store.unavailableWords == nil && store.authProblem == nil && store.readError == nil)
                #expect(store.tab == .chats && store.chatRoute.isEmpty)
            }
        }
    }

    /// **A phone with a hub keeps it, and its key, when a link names another hub** (`MobileStore.openLink`): a phone
    /// that dropped its key for every link would leave its fleet for any picture, and its key would go with it. Nothing
    /// goes to either hub, and Add this phone shows the link's code with the reason.
    @MainActor @Test("a link to another hub moves no phone that has a hub and a key, and sends nothing",
                     .timeLimit(.minutes(1)))
    func aLinkToAnotherHubMovesNoPhone() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let own = LinkHub(), other = LinkHub()
                defer { own.stop(); other.stop() }
                let ownAddress = try await own.start(), otherAddress = try await other.start()
                // Both answer an enrolment at once, so a phone that went to one would not wait for the check.
                own.answerEnrolment()
                other.answerEnrolment()
                let holder = DeviceKey(account: "device-key-link-check")
                try holder.remove()
                defer { try? holder.remove() }
                try holder.save("the-key-of-this-phones-own-hub")
                UserDefaults.standard.set(ownAddress, forKey: "hubAddress")
                let store = Self.store(holder, named: "device-key-link-check")
                #expect(store.hub.absoluteString == ownAddress + "/" && store.keyState == .locked)
                await store.openLink(try #require(URL(string: "fleet://enroll?hub=\(otherAddress)&code=ABCD-2345")))
                #expect(other.log.isEmpty && own.log.isEmpty)
                #expect(store.hub.absoluteString == ownAddress + "/" && store.keyState == .locked)
                #expect(try holder.pressKey() == "the-key-of-this-phones-own-hub")
                let linked = try #require(store.takeLinkedCode())
                #expect(linked.code == "ABCD-2345" && linked.otherHub)
                #expect(linked.problem == "This code is for another hub. Forget this phone's key in Settings first.")
                #expect(store.tab == .chats && store.chatRoute == [.settings, .enroll])
            }
        }
    }

    /// **A code that the hub refuses leaves this phone's keys as they were** (the read of F9 piece 3, finding 2): the
    /// enrolment of the Mac's picture made the new signing key and recovery key in the phone's own items, and removed its
    /// recovery copy, before the hub answered. Any link with a wrong code then took away the key that signs a yes to a
    /// door call and the copy that the hub's record still named. A code that the hub takes moves the new keys in.
    @MainActor @Test("a refused code leaves the signing key, the recovery key and the recovery copy as they were, and a taken one replaces them",
                     .timeLimit(.minutes(1)))
    func aRefusedCodeKeepsThePhonesKeys() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = LinkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                hub.answerEnrolment()
                hub.refuseCodes(true)
                // Items of the check's own: the keys of an enrolled phone are never touched.
                let key = DeviceKey(account: "device-key-keys-check")
                let signing = DeviceSigningKey(account: "signing-key-keys-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-keys-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-keys-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                let oldSigning = try signing.make(), oldRecovery = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let store = MobileStore(deviceKey: key, signingKey: signing, recoveryKey: recovery, recoveryCopy: copy)
                let bind = DeviceBinding.newBind()
                // A wrong code, as any link can bring: the hub refuses it, and nothing of the phone's changed.
                #expect(await store.enroll(code: "ABCD-2345", bind: bind, read: false) == MobileError.codeDidNotWork)
                #expect(hub.enrolment?["signing_key"] != nil)
                #expect(try Self.signs(signing, as: oldSigning))
                #expect(Self.opens(recovery, sealedTo: oldRecovery))
                #expect(copy.held)
                // The right code: the hub takes it, and the keys that went with it are the phone's now.
                hub.refuseCodes(false)
                #expect(await store.enroll(code: "ABCD-2345", bind: bind, read: false) == nil)
                let sent = try #require(hub.enrolment)
                #expect(sent["signing_key"] != oldSigning && sent["recovery_key"] != oldRecovery)
                #expect(try Self.signs(signing, as: sent["signing_key"]))
                #expect(Self.opens(recovery, sealedTo: sent["recovery_key"]))
                #expect(!copy.held)
            }
        }
    }

    /// **Two enrolments at once: the second waits for the first, and the phone keeps the keys of the one that the hub
    /// took** (the validator's finding 1 of the enroll key fix, and the second reader's round 4, items 6 and 7, and
    /// round 5, N1): each scan of the Mac's picture starts an enrolment, and a person whose first scan waits scans
    /// again. Side by side, the first one's end removed the second one's new keys, or the first one's yes moved in the
    /// second one's, and the phone held a key that the hub did not take; a second one refused after a taken one said
    /// "This code did not work" on a phone that had just joined, also when the phone could not keep the first one's
    /// keys, whose words were then lost. Here the first is refused, and the second goes and is taken; or the first is
    /// taken, and the second does not go and says what the first said: joined, or the keys that could not be kept.
    @MainActor @Test("two enrolments at once: one goes at a time, and the phone keeps the keys and the key of the one that the hub took",
                     .timeLimit(.minutes(1)), arguments: ["the first refused", "the first taken", "the first taken and not kept"])
    func twoEnrolmentsAtOnce(outcome: String) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let key = DeviceKey(account: "device-key-two-check")
                let signing = DeviceSigningKey(account: "signing-key-two-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-two-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-two-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                let oldSigning = try signing.make(), oldRecovery = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let store = MobileStore(deviceKey: key, signingKey: signing, recoveryKey: recovery, recoveryCopy: copy)
                let bind = DeviceBinding.newBind()
                let notKept = "This phone could not keep its key. Make a new code."
                // The same code twice when the first is taken (a second scan of one picture), and two codes else.
                let secondCode = outcome == "the first refused" ? "EFGH-6789" : "ABCD-2345"
                let first = Task { await store.enroll(code: "ABCD-2345", bind: bind, read: false) }
                try await Self.until { hub.waiting == 1 }
                let ended = Flag()
                let second = Task {
                    defer { ended.set() }
                    return await store.enroll(code: secondCode, bind: bind, read: false)
                }
                // The second waits on the phone, not at the hub: only the first waits there.
                for _ in 0..<10 { await Task.yield() }
                #expect(hub.waiting == 1)
                switch outcome {
                case "the first refused":
                    hub.decide("ABCD2345", takes: false)
                    #expect(await first.value == MobileError.codeDidNotWork)
                    try await Self.until { hub.waiting == 1 }
                    hub.decide("EFGH6789", takes: true)
                    #expect(await second.value == nil)
                default:
                    let kept = outcome == "the first taken"
                    hub.decide("ABCD2345", takes: true,
                               key: kept ? CodeHub.key(for: "ABCD2345") : String(repeating: "k", count: 600))
                    #expect(await first.value == (kept ? nil : notKept))
                    // The second ends with what the first said, and nothing of it reaches the hub.
                    try await Self.until { ended.value || hub.waiting > 0 }
                    #expect(hub.waiting == 0, "the second enrolment went after a taken one")
                    hub.decide("ABCD2345", takes: false)
                    #expect(await second.value == (kept ? nil : notKept))
                    #expect(kept || store.enrollDetail != nil)
                }
                if outcome == "the first taken and not kept" {
                    #expect(try Self.signs(signing, as: oldSigning) && Self.opens(recovery, sealedTo: oldRecovery))
                    #expect(copy.held && !key.has)
                } else {
                    let taken = outcome == "the first taken" ? "ABCD2345" : "EFGH6789"
                    let sent = try #require(hub.enrolment(taken))
                    #expect(sent["signing_key"] != oldSigning)
                    #expect(try Self.signs(signing, as: sent["signing_key"]))
                    #expect(Self.opens(recovery, sealedTo: sent["recovery_key"]))
                    #expect(!copy.held)
                    #expect(try key.pressKey() == CodeHub.key(for: taken) && store.keyState == .ready)
                }
            }
        }
    }

    /// **A taken code whose keys cannot move in says so, and the phone keeps all that it had** (the validator's finding
    /// 2 of the enroll key fix, Hub core's read of it, its round 2 and the second reader's round 4, item 4): a key that
    /// could not move in went with no word, and the phone signed its yes to a door call with a key that the hub no
    /// longer named; a key that moved in could stand beside one that did not; a key whose copy for a press failed
    /// stayed, also when its removal failed after it had taken the key (round 5, N2); the undo of a failed move wrote
    /// again the items that the move had not touched; and it deleted the new key of an item whose old key could not be
    /// read, which it must leave (round 7). Here the keychain
    /// refuses one write after its delete, as a keychain that fails does: the signing key's (and it would refuse the
    /// recovery key's next write too, which the move never makes), the recovery key's after the signing key moved in,
    /// or the copy for a press of the hub's key, and then the removal of that copy; or the hub gives a key that the
    /// phone cannot keep, also after an old recovery key that could not be read. What stays, each
    /// time: the phone's signing key, its recovery key and its recovery copy, as they were, and no key that the hub
    /// takes: the phone's earlier key, or none where the save had taken it away before it failed.
    @MainActor @Test("a taken code whose keys cannot move in says so, and the phone keeps its keys and its copy as they were, and no key that the hub takes",
                     .timeLimit(.minutes(1)),
                     arguments: ["the signing key", "the recovery key", "the hub's key", "the copy for a press",
                                 "the copy for a press and its removal",
                                 "the hub's key, after an old recovery key that cannot be read"])
    func aMoveInThatFailsSaysSo(failing: String) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let key = DeviceKey(account: "device-key-move-check")
                let signing = DeviceSigningKey(account: "signing-key-move-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-move-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-move-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                try key.save("the key of an earlier enrolment")
                let oldSigning = try signing.make(), oldRecovery = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                // The same items, as a keychain that refuses one write gives them to the store.
                func fault(_ item: String...) -> KeyFault? { item.contains(failing) ? KeyFault(adds: 1) : nil }
                let store = MobileStore(
                    deviceKey: DeviceKey(account: "device-key-move-check").failing(
                        failing == "the copy for a press and its removal" ? KeyFault(adds: 1, pressDeletesAfterAdd: 1)
                            : fault("the copy for a press")),
                    signingKey: DeviceSigningKey(account: "signing-key-move-check").failing(fault("the signing key")),
                    recoveryKey: DeviceRecoveryKey(account: "recovery-key-move-check")
                        .failing(failing.hasSuffix("cannot be read") ? KeyFault(reads: 1)
                                    : fault("the recovery key", "the signing key")),
                    recoveryCopy: copy)
                let join = Task { await store.enroll(code: "ABCD-2345", bind: DeviceBinding.newBind(), read: false) }
                try await Self.until { hub.waiting == 1 }
                hub.decide("ABCD2345", takes: true,
                           key: failing.hasPrefix("the hub's key") ? String(repeating: "k", count: 600)
                                : CodeHub.key(for: "ABCD2345"))
                #expect(await join.value == "This phone could not keep its key. Make a new code.")
                #expect(store.enrollDetail != nil)
                #expect(hub.enrolment("ABCD2345")?["signing_key"] != nil && hub.enrolment("ABCD2345")?["recovery_key"] != nil)
                #expect(try Self.signs(signing, as: oldSigning))
                if failing.hasSuffix("cannot be read") {
                    // The old recovery key could not be read, so it has no undo: the new one stays, and is not deleted.
                    #expect(Self.opens(recovery, sealedTo: hub.enrolment("ABCD2345")?["recovery_key"]))
                } else {
                    #expect(Self.opens(recovery, sealedTo: oldRecovery))
                }
                #expect(copy.held)
                if failing.hasPrefix("the copy for a press") {
                    // The save took the earlier key away before it wrote the hub's, and the hub's went again.
                    #expect(!key.has && store.keyState != .ready)
                } else {
                    #expect(try key.pressKey() == "the key of an earlier enrolment" && store.keyState == .locked)
                }
            }
        }
    }

    /// **After a taken code the phone keeps what the hub keeps** (the second reader's round 4, items 1 and 2): the hub
    /// drops the signing key and the recovery key of an enrolment that carries none, and the record of each recovery
    /// copy, but the phone kept its old ones, so its yes to a door call was signed with a key that the hub refused, and
    /// it held a copy that the hub's record no longer named. Here a link whose recovery key could not be made, a typed
    /// code, which carries no key at all, and a link on a phone whose old recovery key cannot be read (round 6: that
    /// read stopped every enrolment).
    @MainActor @Test("after a taken code the phone keeps no signing key, recovery key or copy that the hub does not keep",
                     .timeLimit(.minutes(1)),
                     arguments: ["a link whose recovery key was not made", "a typed code",
                                 "a link on a phone whose old recovery key cannot be read"])
    func aTakenCodeLeavesWhatTheHubKeeps(enrolment: String) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let key = DeviceKey(account: "device-key-kept-check")
                let signing = DeviceSigningKey(account: "signing-key-kept-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-kept-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-kept-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                let oldSigning = try signing.make()
                _ = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let link = enrolment != "a typed code", unreadable = enrolment.hasSuffix("cannot be read")
                let store = MobileStore(
                    deviceKey: key, signingKey: signing,
                    recoveryKey: DeviceRecoveryKey(account: "recovery-key-kept-check")
                        .failing(unreadable ? KeyFault(reads: 1) : link ? KeyFault(refusesNew: true) : nil),
                    recoveryCopy: copy)
                let join = Task { await store.enroll(code: "ABCD-2345", bind: link ? DeviceBinding.newBind() : nil, read: false) }
                try await Self.until { hub.waiting == 1 }
                hub.decide("ABCD2345", takes: true)
                #expect(await join.value == nil)
                let sent = try #require(hub.enrolment("ABCD2345"))
                #expect((sent["recovery_key"] != nil) == unreadable && (sent["signing_key"] != nil) == link)
                if link {
                    #expect(try Self.signs(signing, as: sent["signing_key"]) && sent["signing_key"] != oldSigning)
                } else {
                    #expect(try signing.sign("a statement") == nil)
                }
                if unreadable {
                    #expect(Self.opens(recovery, sealedTo: sent["recovery_key"]))
                } else {
                    #expect(!recovery.exists)
                }
                #expect(!copy.held)
                #expect(try key.pressKey() == CodeHub.key(for: "ABCD2345") && store.keyState == .ready)
            }
        }
    }

    /// **A late answer of Face ID does not take the place of the key that an enrolment kept meanwhile** (the second
    /// reader's round 4, item 3, and round 5, N3): a phone in a fleet comes to the front, and its read of the old key
    /// waits for Face ID; the Mac's picture enrols it, and the hub takes the code; the app may leave the front, which
    /// takes the key out of memory; then Face ID passes. The late read set the old key back and wrote it into the copy
    /// for a press, so the phone read the hub with a key that the hub no longer takes.
    ///
    /// After a code whose keys the phone could not keep (round 6), the late read's key goes on: the hub refuses it and
    /// says to add the phone again with a new code, which is the real step; "This phone's key is locked" was not. Its
    /// save deleted the key and then failed, and the read's key is not written as the copy for a press (round 7): a
    /// copy of a key that the hub refuses was all that the keychain then held.
    @MainActor @Test("a late answer of Face ID leaves the key that an enrolment kept meanwhile", .timeLimit(.minutes(1)),
                     arguments: ["kept", "kept, and the app left the front", "not kept"])
    func aLateFaceIDAnswerKeepsTheNewKey(enrolment: String) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let presence = PresenceStandIn()
                let key = DeviceKey(account: "device-key-late-check")
                try? key.remove()
                defer { try? key.remove() }
                try key.save("the key of an earlier enrolment")
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let kept = enrolment != "not kept"
                let store = Self.store(DeviceKey(account: "device-key-late-check").answering(presence)
                                           .failing(kept ? nil : KeyFault(adds: 1)),
                                       named: "device-key-late-check")
                #expect(store.keyState == .locked)
                let unlocking = Task { await store.unlock() }
                try await Self.until { presence.asked }
                let join = Task { await store.enroll(code: "ABCD-2345", read: false) }
                try await Self.until { hub.waiting == 1 }
                hub.decide("ABCD2345", takes: true)
                #expect(await join.value == (kept ? nil : "This phone could not keep its key. Make a new code."))
                if enrolment == "kept, and the app left the front" { store.lockKey() }
                // Face ID passes now, with the key that it read before the enrolment.
                presence.answer("the key of an earlier enrolment")
                await unlocking.value
                #expect(try key.pressKey() == (kept ? CodeHub.key(for: "ABCD2345") : nil))
                #expect(key.has == kept)
                switch enrolment {
                case "kept":
                    #expect(store.keyState == .ready)
                    await store.refresh()
                    #expect(hub.log.last == "GET /ui/mobile with the key of ABCD2345")
                case "not kept":
                    #expect(store.keyState == .ready)
                    await store.refresh()
                    #expect(hub.log.last == "GET /ui/mobile with another key" && store.authProblem == "device_key_mismatch")
                default:
                    #expect(store.keyState == .locked)
                }
            }
        }
    }

    /// **A key whose copy for a press failed and that cannot be taken away stays, and so do the keys that go with it**
    /// (`DeviceKey.KeyStays`; the second reader's round 4, item 5, which had no test): the enrolment undid the signing
    /// key and the recovery key while the hub's key stayed, so the next return linked the phone with its old signing
    /// key. Here the copy for a press is refused, and then the removal of the key: the phone is joined, with the keys
    /// that it sent, and the next unlock writes the copy for a press.
    @MainActor @Test("a key that cannot be taken away after its copy for a press failed stays, and so do the keys that went with it",
                     .timeLimit(.minutes(1)))
    func aKeyThatStaysKeepsItsKeys() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let key = DeviceKey(account: "device-key-stays-check")
                let signing = DeviceSigningKey(account: "signing-key-stays-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-stays-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-stays-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                _ = try signing.make()
                _ = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let store = MobileStore(deviceKey: key.failing(KeyFault(adds: 1, removalsAfterAdd: 1)),
                                        signingKey: signing, recoveryKey: recovery, recoveryCopy: copy)
                let join = Task { await store.enroll(code: "ABCD-2345", bind: DeviceBinding.newBind(), read: false) }
                try await Self.until { hub.waiting == 1 }
                hub.decide("ABCD2345", takes: true)
                #expect(await join.value == nil)
                let sent = try #require(hub.enrolment("ABCD2345"))
                #expect(try Self.signs(signing, as: sent["signing_key"]))
                #expect(Self.opens(recovery, sealedTo: sent["recovery_key"]))
                let pressCopy = try key.pressKey()
                #expect(!copy.held && key.has && pressCopy == nil && store.keyState == .ready)
            }
        }
    }

    /// **An enrolment keeps to the hub of its call** (the validator's round 4 of the enroll key fix): one that waited
    /// read the phone's hub at its turn, so after a move to another hub its code went there; and an answer that came
    /// after the move would have moved its keys in under the other hub. Here the phone moves while the hub answers, or
    /// while a second enrolment waits behind the first: nothing moves in, and the waiting code goes to no hub.
    @MainActor @Test("an enrolment keeps to the hub of its call: a move to another hub meanwhile sends no code there and keeps no key",
                     .timeLimit(.minutes(1)), arguments: [false, true])
    func anEnrolmentKeepsToItsHub(secondWaits: Bool) async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = CodeHub(), other = CodeHub()
                defer {
                    hub.stop()
                    other.stop()
                }
                let address = try await hub.start(), otherAddress = try await other.start()
                let key = DeviceKey(account: "device-key-move-hub-check")
                let signing = DeviceSigningKey(account: "signing-key-move-hub-check")
                let recovery = DeviceRecoveryKey(account: "recovery-key-move-hub-check")
                let copy = RecoveryCodeCopy(account: "recovery-code-move-hub-check")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                let oldSigning = try signing.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                UserDefaults.standard.set(address, forKey: "hubAddress")
                let store = MobileStore(deviceKey: key, signingKey: signing, recoveryKey: recovery, recoveryCopy: copy)
                let bind = DeviceBinding.newBind()
                let first = Task { await store.enroll(code: "ABCD-2345", bind: bind, read: false) }
                try await Self.until { hub.waiting == 1 }
                let second = secondWaits ? Task { await store.enroll(code: "EFGH-6789", bind: bind, read: false) } : nil
                for _ in 0..<10 { await Task.yield() }
                // The phone moves to another hub, and only then does the first hub answer.
                store.addressText = otherAddress
                await store.connect()
                #expect(store.hub.absoluteString == otherAddress + "/")
                hub.decide("ABCD2345", takes: !secondWaits)
                if let second {
                    #expect(await first.value == MobileError.codeDidNotWork)
                    #expect(await second.value == "The hub did not take the code.")
                } else {
                    #expect(await first.value == "This phone could not keep its key. Make a new code.")
                }
                #expect(hub.enrolment("EFGH6789") == nil && other.enrolment("EFGH6789") == nil)
                let signsAsBefore = try Self.signs(signing, as: oldSigning)
                #expect(signsAsBefore && !recovery.exists && copy.held && !key.has)
            }
        }
    }

    /// **Forget the key takes the phone's key and its signing key, and keeps its recovery key and copy** (the second
    /// reader's rounds 5 and 6): the copy is the phone's only copy of the vault's recovery code, which the hub's record
    /// still names. Taken away by a press that asks nothing, or by A1's drop before a link that then failed, it was
    /// lost; the next code that the hub takes replaces or removes it.
    @MainActor @Test("Forget the key takes the key and the signing key, and keeps the recovery key and the recovery copy")
    func forgetTheKeyKeepsTheRecoveryCopy() throws {
        let key = DeviceKey(account: "device-key-forget-check")
        let signing = DeviceSigningKey(account: "signing-key-forget-check")
        let recovery = DeviceRecoveryKey(account: "recovery-key-forget-check")
        let copy = RecoveryCodeCopy(account: "recovery-code-forget-check")
        defer {
            try? key.remove()
            try? signing.remove()
            try? recovery.remove()
            copy.remove()
        }
        try key.save("the key of an earlier enrolment")
        _ = try signing.make()
        let oldRecovery = try recovery.make()
        try copy.keep(Data("the copy of an earlier enrolment".utf8))
        let store = MobileStore(deviceKey: key, signingKey: signing, recoveryKey: recovery, recoveryCopy: copy)
        #expect(store.forgetKey() == nil)
        let signed = try signing.sign("a statement")
        #expect(!key.has && signed == nil && store.keyState == .none)
        #expect(Self.opens(recovery, sealedTo: oldRecovery) && copy.held)
    }

    /// **A link that fails on a phone in no fleet keeps its recovery copy** (the second reader's round 6): A1 drops a
    /// kept key before the hub answers, and with it went the recovery key and the copy, so a reinstalled phone that
    /// scanned an expired picture, a wrong one or a stranger's had lost the vault's recovery code, while the hub's
    /// record still named it.
    @MainActor @Test("a link that fails on a phone in no fleet drops the kept key and keeps the recovery key and the copy",
                     .timeLimit(.minutes(1)))
    func aFailedLinkKeepsTheRecoveryCopy() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = LinkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                hub.answerEnrolment()
                hub.refuseCodes(true)
                let name = "device-key-reinstall-check"
                let key = DeviceKey(account: name)
                let signing = DeviceSigningKey(account: name + "-signing")
                let recovery = DeviceRecoveryKey(account: name + "-recovery")
                let copy = RecoveryCodeCopy(account: name + "-copy")
                func clear() {
                    try? key.remove()
                    try? signing.remove()
                    try? recovery.remove()
                    copy.remove()
                }
                clear()
                defer { clear() }
                // What a reinstall finds: the keychain of the earlier install, and no hub.
                try key.save("a-key-that-an-earlier-install-left")
                _ = try signing.make()
                let oldRecovery = try recovery.make()
                try copy.keep(Data("the copy of an earlier enrolment".utf8))
                let store = Self.store(key, named: name)
                #expect(store.hasNoHub && store.keyState == .locked)
                let link = "fleet://enroll?hub=\(address)&code=ABCD-2345&bind=\(DeviceBinding.newBind())"
                await store.openLink(try #require(URL(string: link)))
                #expect(store.takeLinkedCode()?.problem == MobileError.codeDidNotWork)
                let signed = try signing.sign("a statement")
                #expect(!key.has && signed == nil)
                #expect(Self.opens(recovery, sealedTo: oldRecovery) && copy.held)
            }
        }
    }

    /// **A store whose key items are all the check's own** (`name`, and its own names for the signing key, the recovery
    /// key and the copy): an enrolment writes and removes each of them, and the keys of an enrolled phone are never
    /// touched.
    @MainActor static func store(_ holder: DeviceKey, named name: String) -> MobileStore {
        MobileStore(deviceKey: holder, signingKey: DeviceSigningKey(account: name + "-signing"),
                    recoveryKey: DeviceRecoveryKey(account: name + "-recovery"),
                    recoveryCopy: RecoveryCodeCopy(account: name + "-copy"))
    }

    /// The holder signs with the key whose public half (standard base64 of `04 || X || Y`) is `publicKey`.
    private static func signs(_ holder: DeviceSigningKey, as publicKey: String?) throws -> Bool {
        let statement = "a statement of the check"
        guard let publicKey, let point = Data(base64Encoded: publicKey), let signature = try holder.sign(statement),
              let der = Data(base64Encoded: signature) else { return false }
        return try P256.Signing.PublicKey(x963Representation: point)
            .isValidSignature(P256.Signing.ECDSASignature(derRepresentation: der), for: Data(statement.utf8))
    }

    /// The holder opens a box that is sealed to the key whose public half is `publicKey`, as the Mac seals the code.
    private static func opens(_ holder: DeviceRecoveryKey, sealedTo publicKey: String?) -> Bool {
        let code = Data("a recovery code".utf8)
        guard let publicKey, let box = try? RecoverySeal.seal(code, to: publicKey, device: "phone-check") else {
            return false
        }
        return (try? holder.open(box, device: "phone-check")) == code
    }

    /// Where the store keeps its files on this phone.
    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FleetMobile")

    /// Everything that the store keeps between launches, apart from the outbox: a check compares it before and after.
    @MainActor private static func keptState() -> NSDictionary {
        var kept: [String: Any] = [:]
        for key in ["agentDrafts", "answerDrafts", "mobileRepliesSeen", "stagedFiles"] {
            kept[key] = UserDefaults.standard.object(forKey: key) ?? "none"
        }
        for name in ["snapshot.json", "chats.json"] {
            kept[name] = (try? Data(contentsOf: support.appendingPathComponent(name))) ?? "none"
        }
        return kept as NSDictionary
    }

    /// Runs `body` on a phone with no hub address saved, and puts back the one that the simulator had.
    @MainActor private static func withoutHub(_ body: () async throws -> Void) async throws {
        let saved = UserDefaults.standard.string(forKey: "hubAddress")
        UserDefaults.standard.removeObject(forKey: "hubAddress")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "hubAddress") }
            else { UserDefaults.standard.removeObject(forKey: "hubAddress") }
        }
        try await body()
    }

    /// Runs `body` and puts back what a read of a hub writes to this phone: the fleet and the chats that it keeps, the
    /// replies that it saw, and the drafts, the staged files and the generations that a read records for them (a read
    /// of another generation empties them).
    @MainActor private static func keepingReadings(_ body: () async throws -> Void) async throws {
        let files = ["snapshot.json", "chats.json"].map { support.appendingPathComponent($0) }
        let kept = files.map { try? Data(contentsOf: $0) }
        let values = ["mobileRepliesSeen", "composersPlace", "answerDraftsPlace", "agentDrafts", "stagedFiles"]
            .map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (file, data) in zip(files, kept) {
                if let data { try? data.write(to: file, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            for (name, value) in values {
                if let value { UserDefaults.standard.set(value, forKey: name) }
                else { UserDefaults.standard.removeObject(forKey: name) }
            }
        }
        try await body()
    }

    /// Waits until `done` holds: it looks again every 20 ms, and the event ends the wait, not a time. The bound, 20 s
    /// inside the test's own limit, only makes a regression fail at the expectation that follows, in place of a hang.
    @MainActor private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<1_000 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// **A hub on this Mac's loopback**, for a check of the phone's own client: it listens on the loopback alone, takes each
/// request once its head and its whole body are here, and answers it as its kind says (`answer`). Each answer closes its
/// connection, and the hub keeps the requests that its kind notes, in order.
private class LoopbackHub: @unchecked Sendable {
    /// Each request that the hub notes, as it comes.
    let requests: AsyncStream<String>
    private let arrived: AsyncStream<String>.Continuation
    private let queue: DispatchQueue
    let lock = NSLock()
    private var listener: NWListener?
    private var seen: [String] = []

    init(label: String) {
        queue = DispatchQueue(label: label)
        let made = AsyncStream.makeStream(of: String.self)
        requests = made.stream
        arrived = made.continuation
    }

    /// Every request so far, in order.
    var log: [String] { lock.withLock { seen } }

    /// Starts listening on the loopback alone, and gives the hub's address.
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
        var tries = 0
        while (listener.port?.rawValue ?? 0) == 0, tries < 150 {
            tries += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let port = listener.port?.rawValue, port != 0 else { throw URLError(.cannotConnectToHost) }
        return "http://127.0.0.1:\(port)"
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        arrived.finish()
    }

    /// One whole request, which the hub's kind answers. A hub of no kind cuts it.
    func answer(_ request: Request, on connection: NWConnection) { connection.cancel() }

    private func take(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, bytes: Data())
    }

    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] piece, _, done, error in
            guard let self, error == nil else { return connection.cancel() }
            let all = bytes + (piece ?? Data())
            if let request = Request(all) { return self.answer(request, on: connection) }
            if done || all.count > 1_000_000 { return connection.cancel() }
            self.read(connection, bytes: all)
        }
    }

    func note(_ request: String) {
        lock.withLock { seen.append(request) }
        arrived.yield(request)
    }

    func send(_ reply: Data, on connection: NWConnection) {
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func reply(_ status: Int, _ body: String) -> Data {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Refused")\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    /// One request, once its head and its whole body are here.
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init?(_ bytes: Data) {
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard bytes.count - end.upperBound >= length else { return nil }
            method = String(first[0])
            path = String(first[1].split(separator: "?").first ?? "")
            self.headers = headers
            body = Data(bytes[end.upperBound...].prefix(length))
        }
    }
}

/// **A hub that holds each enrolment until the check decides it** (two enrolments at once, a move-in that fails): it
/// keeps the fields of each by its code, and takes it with a key or refuses it as a wrong code, when the check says.
private final class CodeHub: LoopbackHub, @unchecked Sendable {
    /// The key that the hub gives for `code`: each code its own, so a check sees which enrolment the phone kept.
    static func key(for code: String) -> String { "a-key-for-" + code.lowercased() }
    private var held: [String: NWConnection] = [:]
    private var fields: [String: [String: String]] = [:]
    private var given: [String: String] = [:]

    init() { super.init(label: "founderizer.check.code-hub") }

    /// How many enrolments wait for the check.
    var waiting: Int { lock.withLock { held.count } }

    /// The fields of the enrolment of `code` (as the phone sends it: no dash), as the phone sent them.
    func enrolment(_ code: String) -> [String: String]? { lock.withLock { fields[code] } }

    /// The enrolment of `code` gets its answer: `key`, or the refusal of a wrong code.
    func decide(_ code: String, takes: Bool, key: String? = nil) {
        let key = key ?? Self.key(for: code)
        guard let connection = lock.withLock({ () -> NWConnection? in
            if takes { given[key] = code }
            return held.removeValue(forKey: code)
        }) else { return }
        send(takes ? Self.reply(200, #"{"device": "phone-check", "label": "iPhone", "key": "\#(key)"}"#)
                   : Self.reply(403, #"{"error": "that code is not valid", "code": "code_not_valid"}"#), on: connection)
    }

    override func stop() {
        let left = lock.withLock { () -> [NWConnection] in
            defer { held = [:] }
            return Array(held.values)
        }
        left.forEach { $0.cancel() }
        super.stop()
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        if route == "GET /ui/mobile" {
            let bearer = request.headers["authorization"].map { String($0.dropFirst("Bearer ".count)) }
            let code = lock.withLock { bearer.flatMap { given[$0] } }
            note(route + (code.map { " with the key of " + $0 } ?? (bearer == nil ? " with no key" : " with another key")))
            return send(code == nil ? Self.reply(403, #"{"error": "device key mismatch", "auth": "device_key_mismatch"}"#)
                                    : Self.reply(200, Self.fleet), on: connection)
        }
        guard route == "POST /ui/owner/enroll",
              let sent = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
              let code = sent["code"] else {
            note(route)
            return send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
        lock.withLock {
            fields[code] = sent
            held[code] = connection
        }
        note(route + " " + code)
    }

    /// The hub's compact read of a fleet with nothing in it.
    private static let fleet = #"{"schema_version": 1, "db": "gen-code", "time": 1800000000, "ui_features": ["mobile"], "#
        + #""agents": [], "needs": [], "tasks": [], "recent": [], "holds": [], "outcomes": []}"#
}

/// A mark that a task sets when it ends, which a check reads from the main actor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

/// **The network of a phone with no hub, as a check sees it** (`SampleFleetTests.noHub`): each request to the built-in
/// address, which names no hub, is counted and answered as no network answers it, with no such host.
private final class NoHubNetwork: URLProtocol {
    static let host = URL(string: HubClient.defaultAddress)?.host ?? "fleet.invalid"
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }
    override func stopLoading() {}
}

/// **The network of a phone whose hub does not answer, as a check sees it** (`SampleFleetTests.joinWithNoAnswer`): each
/// request to the hub's address is kept by its path and runs out of time, as one does behind a tunnel that is off.
private final class SilentHubNetwork: URLProtocol {
    static let host = "100.84.1.2"
    static let paths = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.withLock { $0.append(request.url?.path ?? "") }
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

/// **A hub for the Mac's code link** (`MobileStore.openLink`): it refuses a read with no key in the hub's words for an
/// owner device, gives a key for the code, and answers a read that carries that key. It holds its answer to the
/// enrolment until the check has looked at the phone, and it keeps every request, in order, with the key that it
/// carried: its own, another one or none.
private final class LinkHub: LoopbackHub, @unchecked Sendable {
    static let key = "a-key-that-the-check-hub-gave"
    /// The enrolment's connection and its answer, until the check lets the answer go.
    private var held: (connection: NWConnection, reply: Data)?
    private var letGo = false
    /// The hub refuses each code, as it refuses a wrong one (`refuseCodes`).
    private var refuses = false
    private var enrolled: [String: String]?

    /// The fields of the last enrolment, as the phone sent them.
    var enrolment: [String: String]? { lock.withLock { enrolled } }

    func refuseCodes(_ value: Bool) { lock.withLock { refuses = value } }

    init() { super.init(label: "founderizer.check.link-hub") }

    override func stop() {
        let held = lock.withLock { () -> NWConnection? in
            defer { self.held = nil }
            return self.held?.connection
        }
        held?.cancel()
        super.stop()
    }

    /// The answer to the enrolment goes.
    func answerEnrolment() {
        let held = lock.withLock { () -> (connection: NWConnection, reply: Data)? in
            letGo = true
            defer { self.held = nil }
            return self.held
        }
        if let held { send(held.reply, on: held.connection) }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        switch route {
        case "GET /ui/mobile":
            let bearer = request.headers["authorization"], keyed = bearer == "Bearer \(Self.key)"
            note(route + (keyed ? " with the key" : bearer == nil ? " with no key" : " with another key"))
            send(keyed ? Self.reply(200, Self.fleet)
                       : Self.reply(403, #"{"error": "device key required", "auth": "device_key_required"}"#),
                 on: connection)
        case "POST /ui/owner/enroll":
            // An enrolment carries no key: one that came with it would be a key of another hub.
            note(route + (request.headers["authorization"] == nil ? "" : " with a key"))
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String]
            let refused = lock.withLock { () -> Bool in
                enrolled = fields
                return refuses
            }
            let reply = refused ? Self.reply(403, #"{"error": "that code is not valid", "code": "code_not_valid"}"#)
                : Self.reply(200, #"{"device": "phone-check", "label": "iPhone", "key": "\#(Self.key)"}"#)
            let now = lock.withLock { () -> Bool in
                if letGo { return true }
                held = (connection, reply)
                return false
            }
            if now { send(reply, on: connection) }
        default:
            note(route)
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The hub's compact read of a fleet with nothing in it.
    private static let fleet = #"{"schema_version": 1, "db": "gen-link", "time": 1800000000, "ui_features": ["mobile"], "#
        + #""agents": [], "needs": [], "tasks": [], "recent": [], "holds": [], "outcomes": []}"#
}

/// **A hub with one card that takes his message under it** (Needs clarification on every card, owner feature
/// `need_clarify`): it answers a read with that card, and his message under it as `mode` says: with the hub's receipt of
/// the command, whose talk has the message; by a cut connection before it takes the message, as a hub that went away;
/// by a cut connection after it took the message, as an answer that was lost on its way back; or with the hub's
/// refusal. A repeat of a request that it took gets that request's first result, as the hub's own record answers it.
/// Its read has the messages that it took only while `readsTalk` is set: else they have not reached that read yet.
private final class TalkHub: LoopbackHub, @unchecked Sendable {
    enum Mode { case answers, cutsBefore, cutsAfter, refuses }
    private var answering = Mode.answers
    private var reading = false
    private var ids: [String] = []
    /// The messages that it took, by request, in order.
    private var taken: [(id: String, text: String)] = []

    init() { super.init(label: "founderizer.check.talk-hub") }

    var mode: Mode {
        get { lock.withLock { answering } }
        set { lock.withLock { answering = newValue } }
    }

    var readsTalk: Bool {
        get { lock.withLock { reading } }
        set { lock.withLock { reading = newValue } }
    }

    /// The request number of each message that came, a cut one too, in order.
    var messages: [String] { lock.withLock { ids } }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        note(route)
        switch route {
        case "GET /ui/mobile":
            send(Self.reply(200, fleet()), on: connection)
        case "POST /ui/needs/7/talk":
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            guard let id = fields["request_id"] as? String, let text = fields["text"] as? String else {
                return send(Self.reply(400, #"{"error": "request_id and text are required"}"#), on: connection)
            }
            let (mode, lines) = lock.withLock { () -> (Mode, [(id: String, text: String)]) in
                ids.append(id)
                let known = taken.contains { $0.id == id }
                if !known && (answering == .answers || answering == .cutsAfter) { taken.append((id, text)) }
                return (known ? .answers : answering, taken)
            }
            switch mode {
            case .cutsBefore, .cutsAfter:
                connection.cancel()
            case .refuses:
                send(Self.reply(409, #"{"error": "this request takes no message now"}"#), on: connection)
            case .answers:
                let talk = Self.talk(lines.prefix { $0.id != id } + lines.filter { $0.id == id })
                let receipt: [String: Any] = ["need": 7, "talk": talk, "ok": true, "request_id": id,
                                              "client": request.headers["x-fleet-client"] ?? "", "replayed": false]
                let body = (try? JSONSerialization.data(withJSONObject: receipt)).map { String(decoding: $0, as: UTF8.self) }
                send(Self.reply(200, body ?? "{}"), on: connection)
            }
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The talk's lines of these messages, his, a minute apart.
    private static func talk(_ lines: [(id: String, text: String)]) -> [[String: Any]] {
        lines.enumerated().map { ["who": "owner", "text": $1.text, "ts": 1_800_000_060 + 60 * $0] }
    }

    /// The hub's compact read: one open card of the manager's, with three options, that takes his message under it.
    private func fleet() -> String {
        let talk = readsTalk ? lock.withLock { Self.talk(taken) } : []
        let card: [String: Any] = [
            "id": 7, "by": "manager", "title": "Refund an order from 45 days ago?",
            "why": "A customer asks for a refund 15 days after the 30-day window.", "todo": "", "raised": 1_799_999_000,
            "answer": NSNull(), "answered": NSNull(), "options": ["Refund it", "Offer a 20% voucher", "Say no, politely"],
            "clarify": true, "talk": talk,
        ]
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-talk", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_clarify"], "agents": [], "needs": [card], "tasks": [],
            "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension SampleFleetTests {
    /// **A refused answer holds no other answer** (the owner, 22 November 2026: "cards on the phone are left with
    /// Sending... and never complete"; `MobileStore.canWrite`, `clearRefused`), in the sample fleet, which refuses each
    /// write: his words on card 1 are refused, and a press on card 2 then goes to the hub at once, is refused too, and
    /// takes the place of card 1's request in the Outbox; a new press on card 1 is a new answer, which goes the same
    /// way. Nothing waits behind a refusal. The bug that this stops: a press on any other card waited behind the
    /// refused request with no end, its card said "Sending…", and only a Discard in Settings moved it, on every build
    /// and in the sample in two presses. The bug of before, a press that waited and went by itself after his Discard,
    /// cannot come back: no press waits behind a refusal.
    @MainActor @Test("a refused answer holds no other answer, and leaves the Outbox at the next write",
                     .timeLimit(.minutes(1)))
    func aRefusedAnswerHoldsNoOtherAnswer() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            store.startSample()
            defer { store.leaveSample() }
            await store.refresh()
            try #require(store.canWrite && Set(store.openNeeds.map(\.id)).isSuperset(of: [1, 2]))
            let outbox = Outbox(file: Self.support.appendingPathComponent("pending.json"))

            // his words on card 1 stand in its field at once, as if he had typed them, and the sample refuses them
            let words = "Offer a 20% voucher"
            store.press(needID: 1, words: words)
            #expect(store.answerDraft(for: 1) == words)
            try await Self.until { store.pending?.refusal != nil && !store.sending }
            let first = try #require(store.pending)
            try #require(first.needID == 1 && first.refusal != nil)

            // a press on card 2 goes at once, and the sample refuses it too: card 1's request left the Outbox first
            store.press(needID: 2, choice: 0)
            try await Self.until { store.pending?.needID == 2 && store.pending?.refusal != nil && !store.sending }
            #expect(store.waitingPresses.isEmpty, "a press waits behind a refused answer")
            #expect(store.pending?.needID == 2 && store.pending?.refusal != nil)
            #expect(try outbox.load()?.needID == 2, "the Outbox does not hold card 2's request alone")

            // a new press on card 1 is a new answer, with a number of its own
            store.press(needID: 1, words: words)
            try await Self.until { store.pending?.needID == 1 && store.pending?.refusal != nil && !store.sending }
            #expect(store.waitingPresses.isEmpty)
            #expect(store.pending?.needID == 1 && store.pending?.requestID != first.requestID)
            #expect(try outbox.load()?.requestID == store.pending?.requestID)
        }
    }
}

extension SampleFleetTests {
    /// **His message under a card goes once, as the hub's command** (Needs clarification on every card, owner feature
    /// `need_clarify`): words that look like a key never reach the Outbox or the hub; a message whose send the hub cut
    /// waits unsent with its words, and a press on the card's options behind it is dropped, as behind the card's own
    /// answer; Try again sends the same request, whose receipt is a command's; the message stands in the card from that
    /// receipt; a message whose receipt was lost is confirmed by the next read that has it in the card's talk, and an
    /// older line of his with the same words sends nothing by itself; and the Discard of a refused message gives its
    /// words back to the card's field, never to the manager's chat. Read as an answer's receipt, which has an event and
    /// a time, every message that the hub took waited as "Not sent", and so did each Try again, with every later write
    /// of the phone behind it; a press behind the message waited with no end, and the card said "Sending…" in place of
    /// its "Not sent"; a lost receipt left his message in the talk and in the field at once, under "Not sent".
    @MainActor @Test("a message under a card goes once as the hub's command, and a press does not wait behind it",
                     .timeLimit(.minutes(1)))
    func aMessageUnderACardGoesOnceAsTheHubsCommand() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = TalkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own, which holds none: the reads go with no key, and an enrolled phone's key is
                // never touched.
                let holder = DeviceKey(account: "device-key-talk-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = Self.store(holder, named: "device-key-talk-check")
                try #require(store.pending == nil, "the simulator holds a request of its own")
                // whatever this check leaves in the Outbox goes with it
                defer {
                    if let left = store.pending {
                        try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                let card = try #require(store.openNeeds.first)
                try #require(store.canWrite && card.id == 7 && card.clarifies(features: Array(store.features)))
                let chatDraft = store.draft(for: "manager")

                // a key in his words: nothing is saved, and nothing goes
                await store.talk(needID: 7, words: "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4))
                #expect(store.pending == nil && hub.messages.isEmpty)

                // a send that the hub cut: the message waits unsent with its words, no read looks for it in a chat,
                // and a press on the card is dropped
                let first = "Is it the same customer as last month?"
                store.setClarifyDraft(first, for: 7)
                hub.mode = .cutsBefore
                await store.talk(needID: 7, words: first)
                try #require(store.pending?.talkNeed == 7 && store.pending?.refusal == nil && hub.messages.count == 1)
                await store.refresh()
                #expect(store.waitsUnsent(for: 7) && store.clarifyKept(for: 7) == first && store.readError == nil)
                #expect(hub.log.allSatisfy { $0 == "GET /ui/mobile" || $0 == "POST /ui/needs/7/talk" })
                store.press(needID: 7, choice: 1)
                #expect(store.waitingPresses[7] == nil)

                // Try again: the same request, which the hub's receipt confirms, and the card shows it from that
                // receipt, before a read has it
                hub.mode = .answers
                await store.retry()
                #expect(store.pending == nil && store.sendError == nil)
                #expect(hub.messages.count == 2 && Set(hub.messages).count == 1)
                let talk = store.talk(of: try #require(store.openNeeds.first))
                #expect(talk.map(\.text) == [first] && talk.allSatisfy(\.fromOwner))
                #expect(store.clarifyDraft(for: 7).isEmpty && store.talkReceipts[7] == 1)

                // a receipt that was lost: the next read has the message in the card's talk, and that request goes
                // once more, which the hub's first result confirms
                hub.readsTalk = true
                hub.mode = .cutsAfter
                let second = "And the voucher, does it end this month?"
                await store.talk(needID: 7, words: second)
                // (it goes again in a task of the store's own, and that send ends with a read: until both ended, the
                // store takes no message, and on a slow Mac the next step's message was dropped)
                try await Self.until { store.pending == nil && !store.sending }
                #expect(store.pending == nil && store.talkReceipts[7] == 2)
                #expect(hub.messages.count == 4 && Set(hub.messages).count == 2)
                #expect(store.talk(of: try #require(store.openNeeds.first)).map(\.text) == [first, second])

                // the same words again, cut before the hub took them: his older line with those words is no sign that
                // the hub has them, so no read sends them by itself, and his Try again does
                try #require(store.canWrite)
                hub.mode = .cutsBefore
                await store.talk(needID: 7, words: second)
                // The send's own read has his line with those words. A read that sends them by itself does it in a
                // task of its own, which begins at the first wait of the store after it: the wait of one more read.
                // So, when that read ended and no send is on its way, each send of a read is at the hub.
                await store.refresh()
                try await Self.until { !store.sending }
                #expect(hub.messages.count == 5 && store.pending?.talkNeed == 7 && store.pending?.refusal == nil)
                hub.mode = .answers
                await store.retry()
                #expect(store.pending == nil && hub.messages.count == 6)

                // a refused message: its Discard gives its words back to the card's field, which a start of the app
                // emptied, and never to the manager's chat
                hub.mode = .refuses
                let third = "Can you ask them first?"
                await store.talk(needID: 7, words: third)
                try #require(store.pending?.refusal != nil)
                store.setClarifyDraft("", for: 7)
                store.discardRefused()
                #expect(store.pending == nil && store.clarifyDraft(for: 7) == third)
                #expect(store.draft(for: "manager") == chatDraft)
            }
        }
    }
}

/// **A hub with the manager's chat** (owner features `corrections` and `attachments`): it takes a message and a
/// correction with the hub's receipt, and a file with its number 61, and its chat's read has each message that it took,
/// with the client that sent it. While `holdsReceipts` is set it holds each receipt until `letGo`. It keeps the words
/// of each message and correction that came, in order. Its generation is `database`, which a check can change.
private final class ChatHub: LoopbackHub, @unchecked Sendable {
    private var taken: [(id: String, text: String, client: String, replaces: String?)] = []
    private var holding = false
    private var generation = "gen-chat"
    private var held: [(connection: NWConnection, reply: Data)] = []

    init() { super.init(label: "founderizer.check.chat-hub") }

    /// The words of each message and correction that came, in order.
    var messages: [String] { lock.withLock { taken.map(\.text) } }
    var holdsReceipts: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    var database: String {
        get { lock.withLock { generation } }
        set { lock.withLock { generation = newValue } }
    }

    /// The receipts that it holds go.
    func letGo() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }

    override func stop() {
        let left = lock.withLock { () -> [NWConnection] in
            defer { held = [] }
            return held.map(\.connection)
        }
        for connection in left { connection.cancel() }
        super.stop()
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("GET", "/ui/mobile"):
            send(Self.reply(200, Self.text(Self.fleet.merging(["db": database]) { _, new in new })), on: connection)
        case ("POST", "/ui/attachments"):
            let file: [String: Any] = ["id": 61, "name": request.headers["x-fleet-name"] ?? "file",
                                       "mime": request.headers["content-type"] ?? "", "size": request.body.count,
                                       "sha256": MessageAttachment.digest(request.body), "created": 1_800_000_200,
                                       "kept": NSNull()]
            send(Self.reply(200, Self.text(file)), on: connection)
        case ("GET", "/ui/mobile/chat/manager"):
            let items = lock.withLock { taken }.enumerated().map { index, message -> [String: Any] in
                var item: [String: Any] = ["kind": "message", "ts": 1_800_000_100 + index, "id": message.id,
                                           "text": message.text, "client": message.client]
                if let replaces = message.replaces { item["replaces"] = replaces }
                return item
            }
            let page: [String: Any] = ["db": database, "agent": "manager", "items": items,
                                       "cursor": 1_800_000_100 + max(items.count - 1, 0)]
            send(Self.reply(200, Self.text(page)), on: connection)
        case ("POST", "/ui/messages"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let id = fields["request_id"] as? String ?? "", replaces = fields["replaces_request_id"] as? String
            let client = request.headers["x-fleet-client"] ?? ""
            var receipt: [String: Any] = ["ok": true, "request_id": id, "client": client, "event_id": 201,
                                          "created": 1_800_000_100, "replayed": false]
            if let replaces { receipt["replaces_request_id"] = replaces }
            let reply = Self.reply(200, Self.text(receipt))
            let now = lock.withLock { () -> Bool in
                taken.append((id, fields["text"] as? String ?? "", client, replaces))
                guard holding else { return true }
                held.append((connection, reply))
                return false
            }
            if now { send(reply, on: connection) }
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The hub's compact read, with no generation: the manager alone, on a hub that takes corrections and files.
    private static var fleet: [String: Any] {
        ["schema_version": 1, "time": 1_800_000_000, "ui_features": ["mobile", "corrections", "attachments"],
         "agents": [["name": "manager", "role": "manager", "runtime": "claude", "open_tasks": 0, "usage": []]],
         "needs": [], "tasks": [], "recent": [], "holds": [], "outcomes": []]
    }

    private static func text(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension SampleFleetTests {
    /// **Words that look like a key wait for his choice in the chat's composer** (`KeyInText`; `MobileStore.send(to:keeping:)`
    /// and `sendCorrection(in:keeping:)`; the owner, 22 November 2026: "Keep it, as on the Mac"): a message and a
    /// correction that hold one save nothing and send nothing, their words stay in the box, and the send gives back the
    /// hold that the composer's line and its Keep it show. His Keep it sends exactly those words, once; an edit of the
    /// box asks again, and a correction has its own hold. The send decides it once, on the words that it would send:
    /// also while another write is on its way, where a Keep it sends nothing and its hold stands. The bugs that this
    /// stops: a key typed or pasted into the chat goes to the agent in clear text; a Keep it sends words that he
    /// changed after it, or sends them twice; a hold that a later read of the box decides lets a key go after a write,
    /// or drops a good message.
    @MainActor @Test("a chat message and a correction that look like a key wait for Keep it, and a good message goes",
                     .timeLimit(.minutes(1)))
    func aKeyInTheChatWaitsForKeepIt() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let drafts = UserDefaults.standard.object(forKey: "agentDrafts")
                defer {
                    if let drafts { UserDefaults.standard.set(drafts, forKey: "agentDrafts") }
                    else { UserDefaults.standard.removeObject(forKey: "agentDrafts") }
                }
                let hub = ChatHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own, which holds none: an enrolled phone's key is never touched.
                let holder = DeviceKey(account: "device-key-chat-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                // the chat is open, so each read reads it (a new hub closed every page)
                store.chatRoute = [.chat("manager")]
                try #require(store.canWrite && store.canChat(with: "manager"))
                let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
                typealias Hold = MobileStore.ChatKeyHold

                // a key in a message waits: nothing is saved or sent, and the words stay in the box
                store.setDraft(key, for: "manager")
                let held = try #require(await store.send(to: "manager"), "the composer shows no line about the key")
                #expect(held == Hold(agent: "manager", replaces: nil, words: key))
                #expect(store.pending == nil && hub.messages.isEmpty && store.draft(for: "manager") == key)
                // an edit of the box asks again: his Keep it of the old words sends nothing, and the new words wait
                let edited = key + " for the shop"
                store.setDraft(edited, for: "manager")
                let heldAgain = try #require(await store.send(to: "manager", keeping: held))
                #expect(heldAgain.words == edited && store.pending == nil && hub.messages.isEmpty)
                // Keep it: exactly the kept words go, once
                #expect(await store.send(to: "manager", keeping: heldAgain) == nil)
                #expect(hub.messages == [edited] && store.pending == nil && store.draft(for: "manager").isEmpty)
                #expect(await store.send(to: "manager", keeping: heldAgain) == nil)
                #expect(hub.messages == [edited])

                // a good message goes
                let first = "Ship the newsletter on Monday."
                store.setDraft(first, for: "manager")
                #expect(await store.send(to: "manager") == nil)
                #expect(hub.messages == [edited, first] && store.pending == nil && store.draft(for: "manager").isEmpty)

                // a key in its correction waits, and the correction stays open with its words; the Keep it of a
                // message with the same words sends nothing there, and its own Keep it sends it
                await store.refresh()
                let sent = try #require(store.correctable(in: "manager"))
                store.beginCorrection(sent, in: "manager")
                store.correctionText = key
                let correction = try #require(await store.sendCorrection(in: "manager"), "the composer shows no line about the key")
                #expect(correction == Hold(agent: "manager", replaces: sent.key, words: key))
                #expect(store.pending == nil && hub.messages == [edited, first])
                #expect(await store.sendCorrection(in: "manager", keeping: held) == correction)
                #expect(store.pending == nil && hub.messages == [edited, first] && store.correctionText == key)
                #expect(await store.sendCorrection(in: "manager", keeping: correction) == nil)
                #expect(hub.messages == [edited, first, key] && store.correcting == nil)
                // a good correction goes
                await store.refresh()
                let last = try #require(store.correctable(in: "manager"))
                store.beginCorrection(last, in: "manager")
                let corrected = "Ship the newsletter on Tuesday."
                store.correctionText = corrected
                #expect(await store.sendCorrection(in: "manager") == nil)
                #expect(hub.messages == [edited, first, key, corrected] && store.correcting == nil)

                // a key while another write is on its way: held at the press, a Keep it sends nothing then and its
                // hold stands, and nothing of it goes after that write
                hub.holdsReceipts = true
                let second = "Then tell the customer."
                store.setDraft(second, for: "manager")
                let going = Task { await store.send(to: "manager") }
                try await Self.until { hub.messages.count == 5 }
                try #require(store.sending && store.draft(for: "manager").isEmpty)
                store.setDraft(key, for: "manager")
                let waiting = try #require(await store.send(to: "manager"), "the composer shows no line about the key")
                #expect(await store.send(to: "manager", keeping: waiting) == waiting, "the line went, and nothing was sent")
                hub.holdsReceipts = false
                hub.letGo()
                #expect(await going.value == nil)
                try await Self.until { store.pending == nil && !store.sending }
                try await Task.sleep(for: .milliseconds(500))
                #expect(hub.messages == [edited, first, key, corrected, second] && store.draft(for: "manager") == key)
                // his good words after the held key go, with no hold of before
                let third = "And send me the list."
                store.setDraft(third, for: "manager")
                #expect(await store.send(to: "manager", keeping: waiting) == nil)
                #expect(hub.messages == [edited, first, key, corrected, second] && store.draft(for: "manager") == third)
                #expect(await store.send(to: "manager") == nil)
                #expect(hub.messages == [edited, first, key, corrected, second, third] && store.pending == nil)
            }
        }
    }
}

extension SampleFleetTests {
    /// **The chat page shows the line about a key with Keep it only for the hold of its box** (`ChatPage.keyLine`, its
    /// `onChange` and its Keep it; a Fable reader's probe of 22 November 2026): no line before a Send; after a Send of
    /// words that look like a key, the line and Keep it, and nothing goes; an edit takes them away, and the same words
    /// again do not bring them back; two presses of Keep it in one turn send the words once; a correction's hold shows
    /// in the correction's box and never in the message's box. The bugs that this stops: a Keep it with no hold, or of
    /// the other mode, and a line that stays after an edit.
    @MainActor @Test("the chat page's line about a key has Keep it, which sends once, and an edit or the other mode takes it away",
                     .timeLimit(.minutes(1)))
    func theChatPagesKeepIt() async throws {
        try await Self.withoutHub { try await Self.keepingReadings { try await Self.keepingComposers {
            let hub = ChatHub()
            defer { hub.stop() }
            let address = try await hub.start()
            // A key of the check's own, which holds none: an enrolled phone's key is never touched.
            let holder = DeviceKey(account: "device-key-chat-page-check")
            try holder.remove()
            defer { try? holder.remove() }
            let store = MobileStore(deviceKey: holder)
            try #require(store.pending == nil, "the simulator holds a request of its own")
            defer {
                if let left = store.pending {
                    try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                }
            }
            store.addressText = address
            await store.connect()
            store.chatRoute = [.chat("manager")]
            try #require(store.canWrite && store.canChat(with: "manager"))
            let window = CardWindow(ChatPage(store: store, agent: "manager"))
            defer { window.close() }
            let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
            let line = "That looks like a key. Never send a key in a message."

            // no line before a Send; after it, the line and Keep it, and nothing goes
            store.setDraft(key, for: "manager")
            try await Task.sleep(for: .milliseconds(400))
            #expect(!window.parts.keys.contains("keep-key"), "a line about a key before any Send")
            #expect(window.press("send-goal"))
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.parts.keys.contains("keep-key") && window.labels.contains(line), "no line after the Send")
            #expect(hub.messages.isEmpty && store.pending == nil)
            // an edit takes the line away, and the same words again do not bring it back
            store.setDraft(key + " x", for: "manager")
            try await Task.sleep(for: .milliseconds(400))
            #expect(!window.parts.keys.contains("keep-key"), "the line stays after an edit")
            store.setDraft(key, for: "manager")
            try await Task.sleep(for: .milliseconds(400))
            #expect(!window.parts.keys.contains("keep-key") && !window.labels.contains(line), "the line is back with the same words")
            // Send again, then Keep it twice in one turn: the words go once
            #expect(window.press("send-goal"))
            try await Task.sleep(for: .milliseconds(500))
            try #require(window.parts.keys.contains("keep-key"))
            #expect(window.press("keep-key") && window.press("keep-key"))
            try await Self.until { !hub.messages.isEmpty && store.pending == nil && !store.sending }
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.messages == [key], "Keep it sent \(hub.messages.count) messages")
            #expect(store.draft(for: "manager").isEmpty && !window.parts.keys.contains("keep-key"))
            // a correction's hold shows in the correction's box, and not in the message's box after Cancel
            await store.refresh()
            store.beginCorrection(try #require(store.correctable(in: "manager")), in: "manager")
            try await Task.sleep(for: .milliseconds(300))
            store.correctionText = key + " again"
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("send-correction"))
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.parts.keys.contains("keep-key"), "no line for a correction")
            store.cancelCorrection()
            store.setDraft(key + " again", for: "manager")
            try await Task.sleep(for: .milliseconds(500))
            #expect(!window.parts.keys.contains("keep-key"), "a correction's hold shows in the message's box")
            #expect(hub.messages == [key])
            store.setDraft("", for: "manager")
        } } }
    }
}

extension SampleFleetTests {
    /// **The chats' drafts and the files that he picked belong to their generation** (`MobileStore.readSnapshot`,
    /// `composersPlace`, `forgetComposers`): at the first read of another generation they go, from memory, from the
    /// disk and with the files' bytes; a read of the same one keeps them, also at another form of the hub's address,
    /// and so does a first read with no record, as after an update from a build before it. The bugs that this stops:
    /// the files of an old item 7 stood in the new item 7's box and went with a Send, with the attachment numbers of the
    /// old generation; the same generation at another address (a new code link, the address typed another way) lost
    /// every draft and file (an Opus reader's probe of 22 November 2026).
    @MainActor @Test("a chat's draft and the files that he picked leave at a read of another generation, and stay at the same one",
                     .timeLimit(.minutes(1)))
    func composersLeaveWithTheirGeneration() async throws {
        try await Self.withoutHub { try await Self.keepingReadings { try await Self.keepingComposers {
                UserDefaults.standard.removeObject(forKey: "composersPlace")
                let hub = ChatHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own, which holds none: an enrolled phone's key is never touched.
                let holder = DeviceKey(account: "device-key-generation-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && store.snapshot?.db == "gen-chat")
                let chat = MobileStore.stageKey(agent: "manager"), card = MobileStore.stageKey(need: 7)
                defer { for composer in [chat, card] { for file in store.stagedFiles(for: composer) { store.removeStaged(file, for: composer) } } }
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                }
                store.setDraft("Ship it on Monday.", for: "manager")
                await store.stage(picture, name: "plan.png", mime: "image/png", for: chat)
                await store.stage(picture, name: "plan.png", mime: "image/png", for: card)
                try #require(store.readyFiles(for: chat) == [61] && store.readyFiles(for: card) == [61])
                let bytes = (store.stagedFiles(for: chat) + store.stagedFiles(for: card)).map {
                    Self.support.appendingPathComponent("staged").appendingPathComponent($0.requestID.uuidString.lowercased())
                }
                try #require(bytes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

                // a first read with no record, as after an update from a build before it, keeps what was there before it
                UserDefaults.standard.removeObject(forKey: "composersPlace")
                let restarted = MobileStore(deviceKey: holder)
                await restarted.refresh()
                try #require(restarted.snapshot?.db == "gen-chat")
                #expect(restarted.draft(for: "manager") == "Ship it on Monday.", "a first read with no record took a draft")
                #expect(restarted.readyFiles(for: chat) == [61] && restarted.readyFiles(for: card) == [61],
                        "a first read with no record took the files")

                // a visit to the sample fleet and back keeps them, and a draft that looks like a key, in memory only
                let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
                store.setDraft(key, for: "wren")
                store.startSample()
                try await Self.until { store.sample && store.lastRead != nil }
                store.leaveSample()
                try await Self.until { !store.sample && store.lastRead != nil && store.snapshot?.db == "gen-chat" }
                try #require(!store.sample && store.snapshot?.db == "gen-chat")
                #expect(store.draft(for: "manager") == "Ship it on Monday.", "a visit to the sample took a draft")
                #expect(store.readyFiles(for: chat) == [61] && store.readyFiles(for: card) == [61]
                        && bytes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                        "a visit to the sample took the files")
                #expect(store.draft(for: "wren") == key, "a visit to the sample took a draft that looks like a key")

                // a read of the same generation keeps them
                await store.refresh()
                #expect(store.draft(for: "manager") == "Ship it on Monday.")
                #expect(store.readyFiles(for: chat) == [61] && store.readyFiles(for: card) == [61])
                // so does the same generation at another form of the hub's address
                try #require(address.contains("127.0.0.1"))
                store.addressText = address.replacingOccurrences(of: "127.0.0.1", with: "localhost")
                await store.connect()
                try #require(store.hub.host == "localhost" && store.snapshot?.db == "gen-chat")
                #expect(store.draft(for: "manager") == "Ship it on Monday.", "the same generation lost its draft")
                #expect(store.readyFiles(for: chat) == [61] && store.readyFiles(for: card) == [61],
                        "the same generation lost its files")

                // the first read of another generation: they go, from memory, from the disk and with their bytes
                hub.database = "gen-new"
                await store.refresh()
                try #require(store.snapshot?.db == "gen-new")
                #expect(store.draft(for: "manager").isEmpty, "a chat's draft of the old generation stays")
                #expect(store.stagedFiles(for: chat).isEmpty && store.stagedFiles(for: card).isEmpty,
                        "a file of the old generation stays in its box")
                #expect(!bytes.contains { FileManager.default.fileExists(atPath: $0.path) })
                let next = MobileStore(deviceKey: holder)
                #expect(next.draft(for: "manager").isEmpty && next.stagedFiles(for: chat).isEmpty
                        && next.stagedFiles(for: card).isEmpty)
                // what he writes in the new generation stays at its next read
                store.setDraft("Then tell the customer.", for: "manager")
                await store.refresh()
                #expect(store.draft(for: "manager") == "Then tell the customer.")
        } } }
    }

    /// Runs `body` and puts back the chats' drafts, the staged files and their generation's record, as this phone had
    /// them.
    @MainActor private static func keepingComposers(_ body: () async throws -> Void) async throws {
        let kept = ["agentDrafts", "stagedFiles", "composersPlace"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (name, value) in kept {
                if let value { UserDefaults.standard.set(value, forKey: name) }
                else { UserDefaults.standard.removeObject(forKey: name) }
            }
        }
        try await body()
    }
}

/// How often a share sheet closed itself (`ShareModel`'s `finish`).
@MainActor private final class SheetCloses { var count = 0 }

extension SampleFleetTests {
    /// **Shared words that look like a key wait for his choice in the share sheet** (`ShareModel.send(to:keeping:)`,
    /// `edited`; the owner, 22 November 2026: "Keep it, as on the Mac"), as in the app's chat: nothing is sent and the
    /// sheet stays; a Keep it of words that he changed since sends nothing and asks again; his Keep it sends exactly
    /// those words, once, and the sheet closes; plain words go at once. The bug that this stops: a key in a text that he
    /// shared from any app went to the agent's chat in clear text.
    @MainActor @Test("the share sheet holds shared words that look like a key for Keep it, and plain words go at once",
                     .timeLimit(.minutes(1)))
    func theShareSheetHoldsAKey() async throws {
        let hub = ChatHub()
        defer { hub.stop() }
        let address = try await hub.start()
        // A key of the check's own, which holds none, and a roster of the check's own: the phone's are never touched.
        let holder = DeviceKey(account: "device-key-share-check")
        try holder.remove()
        defer { try? holder.remove() }
        let roster = SharedRoster(hub: try MobileClient.address(address), installation: "founderizer-ios/1/share-check",
                                  snapshot: nil, features: [])
        let closes = SheetCloses()
        let sheet = ShareModel(roster: roster, deviceKey: holder, finish: { closes.count += 1 }, cancel: {})
        await sheet.take([])
        let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)

        // shared words with a key wait: nothing goes, the sheet stays, and the words stay in the field
        sheet.text = key + "\n"
        await sheet.send(to: "manager")
        let held = try #require(sheet.keyHold, "the sheet shows no line about the key")
        #expect(held == ShareModel.KeyHold(agent: "manager", words: key + "\n"))
        #expect(hub.messages.isEmpty && closes.count == 0 && sheet.text == key + "\n")
        // an edit of the field ends the line, and a Keep it of the old words sends nothing: the new words wait
        sheet.text = key + "\nfor the shop"
        sheet.edited(sheet.text)
        #expect(sheet.keyHold == nil)
        await sheet.send(to: "manager", keeping: held)
        let again = try #require(sheet.keyHold, "the sheet shows no line about the key")
        #expect(again.words == key + "\nfor the shop" && hub.messages.isEmpty && closes.count == 0)
        // Keep it: exactly those words go, once, and the sheet closes
        await sheet.send(to: "manager", keeping: again)
        #expect(hub.messages == [key + "\nfor the shop"] && closes.count == 1 && sheet.keyHold == nil)
        await sheet.send(to: "manager", keeping: again)
        #expect(hub.messages.count == 1 && closes.count == 1, "a Keep it sent its words twice")

        // plain words go at once, from a new sheet
        let plain = ShareModel(roster: roster, deviceKey: holder, finish: { closes.count += 1 }, cancel: {})
        await plain.take([])
        plain.text = "https://example.com/post\nRead this one.\n"
        await plain.send(to: "manager")
        #expect(plain.keyHold == nil && closes.count == 2)
        #expect(hub.messages == [key + "\nfor the shop", "https://example.com/post\nRead this one."])
    }
}

/// **A hub with three requests of pictures, and one with none** (owner feature `need_pictures`, owner API 1.285): request
/// 7 has three options and a picture for each, request 8 three options and two pictures, request 9 three options that
/// combine (`multi`) and a picture for each, and request 10 three options that combine and no picture. It gives each
/// picture's bytes and takes an answer to each request with the hub's receipt, and it keeps the body of each answer
/// and the number of each picture that was read, in order. While `holdsPictures` is set,
/// it holds the bytes of each picture, and while `holdsAnswers` is set its receipt of each answer, until `release`.
private final class PictureHub: LoopbackHub, @unchecked Sendable {
    /// Three small pictures, one colour each, drawn here: no photo, logo or name.
    static let pictures: [Data] = [UIColor.brown, UIColor.orange, UIColor.systemTeal].map { colour in
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
    static let ids = [71, 72, 73]
    private var bodies: [(path: String, body: [String: Any])] = []
    private var pictureReads: [Int] = []
    private var picturesHeld = false
    private var answersHeld = false
    private var held: [(connection: NWConnection, reply: Data)] = []

    init() { super.init(label: "founderizer.check.picture-hub") }

    /// The answers that came, by route, in order.
    var answers: [(path: String, body: [String: Any])] { lock.withLock { bodies } }
    /// The number of each picture that the phone read, in the order that the reads came.
    var reads: [Int] { lock.withLock { pictureReads } }
    var holdsPictures: Bool {
        get { lock.withLock { picturesHeld } }
        set { lock.withLock { picturesHeld = newValue } }
    }
    var holdsAnswers: Bool {
        get { lock.withLock { answersHeld } }
        set { lock.withLock { answersHeld = newValue } }
    }

    /// The bytes and receipts that it holds go, and it holds nothing more.
    func release() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            picturesHeld = false
            answersHeld = false
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("GET", "/ui/mobile"):
            send(Self.reply(200, Self.fleet), on: connection)
        case ("GET", let path) where path.hasPrefix("/ui/attachments/"):
            guard let id = Int(path.dropFirst("/ui/attachments/".count)), let index = Self.ids.firstIndex(of: id) else {
                return send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
            }
            let bytes = Self.pictures[index]
            let head = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(bytes.count)\r\n"
                + "Connection: close\r\n\r\n"
            let holds = lock.withLock { pictureReads.append(id); return picturesHeld }
            reply(Data(head.utf8) + bytes, on: connection, holds: holds)
        case ("POST", "/ui/needs/7"), ("POST", "/ui/needs/8"), ("POST", "/ui/needs/9"), ("POST", "/ui/needs/10"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let holds = lock.withLock { bodies.append((request.path, fields)); return answersHeld }
            let receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "client": request.headers["x-fleet-client"] ?? "", "event_id": 101,
                                          "created": 1_800_000_100, "replayed": false]
            let body = (try? JSONSerialization.data(withJSONObject: receipt)).map { String(decoding: $0, as: UTF8.self) }
            reply(Self.reply(200, body ?? "{}"), on: connection, holds: holds)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The reply goes now, or waits for `release`.
    private func reply(_ data: Data, on connection: NWConnection, holds: Bool) {
        let now = lock.withLock { () -> Bool in
            // (a release between the hold's read and this line lets it go now)
            guard holds, picturesHeld || answersHeld else { return true }
            held.append((connection, data))
            return false
        }
        if now { send(data, on: connection) }
    }

    /// One picture as the hub gives it with an item.
    private static func picture(_ index: Int) -> [String: Any] {
        ["id": ids[index], "name": "ad-\(index + 1).png", "mime": "image/png", "size": pictures[index].count,
         "sha256": MessageAttachment.digest(pictures[index]), "created": 1_799_999_000, "kept": NSNull()]
    }

    /// The hub's compact read: requests 7, 8, 9 and 10, all of the manager's.
    private static let fleet: String = {
        let options = ["Dark, the bottle", "Orange, big words", "Blue, the morning"]
        func card(_ id: Int, pictures: [[String: Any]], multi: Bool = false) -> [String: Any] {
            ["id": id, "by": "manager", "title": "Pick the ad for the launch", "why": "Three versions of the launch ad.",
             "todo": "", "raised": 1_799_999_000 + id, "answer": NSNull(), "answered": NSNull(), "options": options,
             "pictures": pictures, "multi": multi]
        }
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-pictures", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_pictures"], "agents": [],
            "needs": [card(7, pictures: (0..<3).map(picture)), card(8, pictures: (0..<2).map(picture)),
                      card(9, pictures: (0..<3).map(picture), multi: true), card(10, pictures: [], multi: true)],
            "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }()
}

/// **A request's card of the app in a window of the check**, with each of its parts as VoiceOver finds it: the check
/// presses a part as VoiceOver does (`accessibilityActivate`), which runs that part's own action, and reads which parts
/// the card has by their identifiers, and their state by their traits. Each test closes its window (`close`).
@MainActor private final class CardWindow {
    let window: UIWindow

    /// **SwiftUI gives its views' parts to an accessibility client only while accessibility is on**: in a test process
    /// nothing turns it on, and the card had no part at all. The system's own switches for an automation client turn it
    /// on (as KIF does) while a window of a check stands, and `close` turns them off again: a test host that ended
    /// before its exit left them on in the simulator.
    private static func accessibility(_ on: Bool) {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let library = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW)
                ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return }
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let set = dlsym(library, name) { unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)(on ? 1 : 0) }
        }
    }

    init(_ card: some View) {
        Self.accessibility(true)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 1600)
        window.rootViewController = UIHostingController(rootView: card)
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Every element under the window that names an identifier, by it.
    var parts: [String: NSObject] {
        var found: [String: NSObject] = [:]
        for next in elements {
            // (SwiftUI's parts answer the identifier's message, and are no UIAccessibilityIdentification)
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let named = next.responds(to: selector) ? next.perform(selector)?.takeUnretainedValue() as? String : nil
            if let id = named, !id.isEmpty { found[id] = next }
        }
        return found
    }

    /// The actions "Copy …" of each element under the window that has one, in each element's order: VoiceOver's copy
    /// of a request's values (`CardValueWords`).
    var copies: [[UIAccessibilityCustomAction]] {
        elements.compactMap { element in
            let copies = (element.accessibilityCustomActions ?? []).filter { $0.name.hasPrefix("Copy ") }
            return copies.isEmpty ? nil : copies
        }
    }

    /// Every element under the window, the window first.
    private var elements: [NSObject] {
        var found: [NSObject] = []
        var waiting: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        while let next = waiting.popLast() {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            found.append(next)
            if let view = next as? UIView { waiting += view.subviews }
            if let children = next.accessibilityElements as? [NSObject] {
                waiting += children
            } else {
                let count = next.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    waiting += (0..<count).compactMap { next.accessibilityElement(at: $0) as? NSObject }
                }
            }
        }
        return found
    }

    /// The words of every element under the window that has some, as VoiceOver reads them.
    var labels: [String] { elements.compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty } }

    /// Where the part with this identifier stands, as VoiceOver finds it.
    func frame(of id: String) -> CGRect? { parts[id]?.accessibilityFrame }

    /// Presses the part with this identifier, as VoiceOver does: true when it took the press.
    func press(_ id: String) -> Bool { parts[id]?.accessibilityActivate() == true }

    /// The names of VoiceOver's actions of the part with this identifier, in their order.
    func actions(of id: String) -> [String] { (parts[id]?.accessibilityCustomActions ?? []).map(\.name) }

    /// Runs the action of this name of the part with this identifier, as VoiceOver does: true when it took it.
    func perform(_ name: String, of id: String) -> Bool {
        guard let action = parts[id]?.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
        return Self.perform(action)
    }

    /// Runs an action of an element as VoiceOver does: true when it took it.
    static func perform(_ action: UIAccessibilityCustomAction) -> Bool {
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target as? NSObject else { return false }
        _ = target.perform(action.selector, with: action)
        return true
    }

    /// The part with this identifier has this trait now (a tick `.selected`, a Send that takes no press `.notEnabled`).
    func has(_ id: String, _ trait: UIAccessibilityTraits) -> Bool { parts[id]?.accessibilityTraits.contains(trait) == true }

    /// The picture that a press opened stands at full screen over the card.
    var opened: Bool { window.rootViewController?.presentedViewController != nil }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        Self.accessibility(false)
    }
}

extension SampleFleetTests {
    /// Runs `body` with a store that read the picture hub, and leaves nothing of it: no key, no reading, no request.
    @MainActor private static func withPictureHub(_ body: (MobileStore, PictureHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let hub = PictureHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-picture-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = Self.store(holder, named: "device-key-picture-check")
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                    let opened = FileManager.default.temporaryDirectory.appendingPathComponent("attachments")
                    for (id, number) in zip(PictureHub.ids, 1...) {
                        try? FileManager.default.removeItem(at: opened.appendingPathComponent("\(id)-ad-\(number).png"))
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && store.openNeeds.map(\.id).sorted() == [7, 8, 9, 10])
                // A press that still waits goes to this hub before the check cleans up: one that went after it stayed
                // in the simulator's Outbox, and each later check of a store found a request there. A press's own task
                // starts on the next turn of the main actor, so the check gives it that turn before it looks.
                var failure: Error?
                do { try await body(store, hub) } catch { failure = error }
                hub.release()
                try? await Task.sleep(for: .milliseconds(300))
                for _ in 0..<60 where !store.waitingPresses.isEmpty || store.sending {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let failure { throw failure }
            }
        }
    }

    /// **A request whose pictures are not one for each option draws the card of before** (owner feature `need_pictures`):
    /// no picture can be known to stand over its own option, so none stands, and the options are the rows of before. A
    /// hub that does not name the feature gets the card of before too. The bug that this stops: two pictures over the
    /// first two of three options, and he picks an ad by the picture of another.
    @MainActor @Test("a request with three options and two pictures draws the card of before", .timeLimit(.minutes(1)))
    func picturesThatAreNotOneForEachOptionDrawNone() async throws {
        try await Self.withPictureHub { store, _ in
            let three = try #require(store.openNeeds.first { $0.id == 7 })
            let two = try #require(store.openNeeds.first { $0.id == 8 })
            #expect(NeedPictures.drawn(three, features: store.features)?.map(\.id) == PictureHub.ids)
            #expect(NeedPictures.drawn(two, features: store.features) == nil)
            #expect(NeedPictures.drawn(three, features: store.features.subtracting(["need_pictures"])) == nil)

            let window = CardWindow(NeedCard(store: store, need: two, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let parts = Set(window.parts.keys)
            #expect(Set(parts.filter { $0.hasPrefix("need-option-8-") })
                    == ["need-option-8-0", "need-option-8-1", "need-option-8-2"])
            #expect(!parts.contains { $0.hasPrefix("need-picture-") })
        }
    }

    /// **A press of the picture opens it at full screen and answers nothing; a press of its words is the answer**
    /// (owner feature `need_pictures`): the words send `choice` with their option's index, as a press of an option does.
    /// A press while the picture's own read runs opens it when its bytes come. The bugs that this stops: a look at a
    /// picture answers the request, with an ad that he did not mean to pick; a press while the card reads the picture
    /// opens nothing.
    @MainActor @Test("a press of the picture answers nothing, and a press of its words sends that option",
                     .timeLimit(.minutes(1)))
    func aPictureOpensAndItsWordsAnswer() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            hub.holdsPictures = true
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Self.until { hub.reads == [71] }
            try #require(hub.reads == [71], "the card did not read its first picture")
            #expect(Set(window.parts.keys.filter { $0.hasPrefix("need-picture-7-") })
                    == ["need-picture-7-0", "need-picture-7-1", "need-picture-7-2"])

            // the first picture, while the card reads it: it opens when its bytes come, and no answer goes or waits
            #expect(window.press("need-picture-7-0"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.opened)
            hub.release()
            try await Self.until { window.opened }
            #expect(window.opened, "the picture did not open")
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.answers.isEmpty && store.pending == nil && store.waitingPresses.isEmpty)
            window.window.rootViewController?.dismiss(animated: false)

            // the second option's words: the answer with that option's index, and nothing else
            #expect(window.press("need-option-7-1"))
            try await Self.until { !hub.answers.isEmpty }
            let answer = try #require(hub.answers.first)
            #expect(hub.answers.count == 1 && answer.path == "/ui/needs/7")
            #expect(answer.body["choice"] as? Int == 1 && answer.body["answer"] == nil && answer.body["choices"] == nil)
        }
    }

    /// **The ticked options go as one answer, each once, in their order, and nothing changes them while the Send waits**
    /// (owner feature `need_pictures`, a request whose options combine): behind another answer on its way, his Send
    /// waits, after its wait with Undo (`MobileStore.hold`); the card stands folded with his answer meanwhile, so no tick
    /// and no Send takes a press until it went, and the hub gets `choices` and no words. The bug that this stops: he
    /// changes the ticks while the Send waits, the card shows the new ones, and the old ones go. **The same on a card
    /// with no pictures** (card 10, `NeedOptions`; found with the owner's point of 22 November 2026 on the phone's
    /// cards): its rows have the ticks and Send. The bug that this stops: the card asks for several answers, and the
    /// phone sends the first option that he presses.
    @MainActor @Test("ticked options go as one answer, and nothing changes them while the Send waits",
                     .timeLimit(.minutes(1)), arguments: [9, 10])
    func tickedOptionsGoAsOneAnswer(card: Int) async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == card })
            store.answerWait = .milliseconds(100)
            // another answer on its way, whose receipt the hub holds
            hub.holdsAnswers = true
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.answers.count == 1 }
            try #require(hub.answers.first?.path == "/ui/needs/7" && store.sending)

            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("need-tick-\(card)-2") && window.press("need-tick-\(card)-0"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.press("need-send-ticked-\(card)"))
            try await Task.sleep(for: .milliseconds(400))
            try #require(store.waitingPresses[card] == .ticked([0, 2]), "the Send did not wait behind the other answer")

            // while it waits: the card stands folded with his two options, and no tick or Send is there to press; Undo
            // stays, because nothing of it left the phone (F10, A5)
            let parts = Set(window.parts.keys)
            #expect(!parts.contains { $0.hasPrefix("need-tick-\(card)-") })
            #expect(!parts.contains("need-send-ticked-\(card)"))
            #expect(parts.contains("need-undo-\(card)"), "the Send that waits behind another answer has no Undo")

            // the other answer's receipt: the Send goes, with the indexes of the ticked options
            hub.release()
            try await Self.until { hub.answers.count == 2 }
            let answer = try #require(hub.answers.last)
            #expect(answer.path == "/ui/needs/\(card)")
            #expect(answer.body["choices"] as? [Int] == [0, 2])
            #expect(answer.body["answer"] == nil && answer.body["choice"] == nil)
        }
    }

    /// **A card reads its pictures one after another, in the order of its options** (owner feature `need_pictures`):
    /// each read has the client's limit of 15 seconds. The bug that this stops: six large pictures read at once on a slow
    /// link, each ends "Not loaded", and he has no picture to choose by.
    @MainActor @Test("a card reads its pictures one after another, in the order of its options", .timeLimit(.minutes(1)))
    func aCardReadsItsPicturesInTurn() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            hub.holdsPictures = true
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Self.until { !hub.reads.isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.reads == [71], "the card read more than one picture at a time")
            hub.release()
            try await Self.until { hub.reads.count == 3 }
            #expect(hub.reads == PictureHub.ids)
        }
    }
}

extension SampleFleetTests {
    /// **Each value that the agent put in inline code on a request's card has VoiceOver's "Copy <value>", which copies
    /// the value exactly; the door's script, his own answer and a chat's message have none** (`NeedPlainWords`,
    /// `CardValueWords`; the owner's "Yes, as drawn" of 21 November 2026 to a chip with a copy icon on each value). The
    /// action is the chip's own copy, as VoiceOver gives it. The bugs that this stops: a chip in the script that the
    /// phone signs, which shows its words as the agent's values; a chip on his own words; a chip in every message of a
    /// chat; and a copy with a character added or cut. **A key card says the Mac once**: its line with the key, and
    /// not the hub's own sentence in its `todo` under "What it wants", which the Mac's card leaves out too (the owner,
    /// 20 November 2026: "I need more brevity and clarity"). The bug that this stops: a kind of request whose `todo` is
    /// a sentence of the hub's, which the card says a second time.
    @MainActor @Test("a card's values copy exactly, only the agent's words have one, and a key card says the Mac once",
                     .timeLimit(.minutes(1)))
    func aCardsValuesCopyExactly() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            func need(_ fields: [String: Any]) throws -> OwnerNeed {
                try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: fields))
            }
            let script = "echo `hostname`\nsystemctl reload nginx\n"
            let call = DoorCall.hash(target: "web-1", action: DoorCall.run, arguments: [], content: Data(script.utf8))
            let door = try need([
                "id": 7, "by": "manager", "title": DoorCall.title(host: "web-1"), "raised": 20, "todo": "",
                "why": "The certificate of `web-1` ends on Friday.", "options": DoorCall.answers(host: "web-1"),
                "door_call": call, "door_fleet": "fleet-1", "door_host": "web-1", "door_script": script,
                "details": DoorCall.details(script: script),
            ])
            let words = try need(["id": 8, "by": "manager", "title": "Paste the key", "raised": 21,
                                  "why": "The shop's mail key ends today.",
                                  "todo": "Paste `ABCD-1234-EFGH` into the box and tap `Save key`."])
            let answered = try need(["id": 9, "by": "manager", "title": "Which server?", "raised": 22, "todo": "",
                                     "why": "Pick the server for `the-shop`.", "options": ["Yes", "No"],
                                     "answer": "Use `staging-2` instead.", "answered": 30])
            try #require(NeedScript.text(door) != nil && NeedOptions.asksInWords(words) && !answered.isOpen)

            /// The names of the copies in a window of `view`, by element, after a press of `opening` when it is set.
            @MainActor func copies(_ view: some View, opening: String? = nil) async throws -> [[String]] {
                let window = CardWindow(view)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(300))
                if let opening {
                    #expect(window.press(opening))
                    try await Task.sleep(for: .milliseconds(300))
                }
                return window.copies.map { $0.map { $0.name } }
            }
            #expect(try await copies(NeedCard(store: store, need: door, header: false), opening: "need-details-7")
                    == [["Copy web-1"]])
            #expect(try await copies(NeedCard(store: store, need: answered, header: true), opening: "need-folded-9")
                    == [["Copy the-shop"]])
            #expect(try await copies(ReplyText(text: "Run `fleet doctor` first.")).isEmpty)

            // a key request, whose todo is the hub's own sentence about the Mac's form (SECRET_TODO in hub.py)
            let key = try need([
                "id": 10, "by": "manager", "kind": "secret", "raised": 23,
                "title": "Enter the API key SHOP_MAIL_KEY for mail.example.com",
                "why": "The shop's mail key ends today, and the agent sends no mail without it.",
                "todo": "Open this request in Founderizer on your Mac and type it into its secure form: it goes "
                    + "straight into the vault, and no agent sees it. Never type the key or the password in a message.",
            ])
            let keyCard = CardWindow(NeedCard(store: store, need: key, header: true))
            try await Task.sleep(for: .milliseconds(300))
            let keyParts = Set(keyCard.parts.keys), keyWords = keyCard.labels
            keyCard.close()
            #expect(keyParts.contains("secret-need-10"), "the key card has no line with the key")
            try #require(keyWords.contains { $0.contains("the agent sends no mail without it") },
                         "the check read none of the card's words")
            #expect(!keyWords.contains { $0.contains("Open this request in Founderizer") },
                    "the key card says the hub's sentence under its own line about the Mac")

            // the two values of the task, behind Details, in their order; the first's copy puts its characters, and
            // only them, on the system's pasteboard
            let window = CardWindow(NeedCard(store: store, need: words, header: false))
            defer {
                window.close()
                UIPasteboard.general.items = []
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("need-details-8"))
            try await Task.sleep(for: .milliseconds(300))
            let found = window.copies
            try #require(found.map { $0.map { $0.name } } == [["Copy ABCD-1234-EFGH", "Copy Save key"]])
            UIPasteboard.general.string = "nothing copied"
            #expect(CardWindow.perform(found[0][0]))
            try await Task.sleep(for: .milliseconds(100))
            #expect(UIPasteboard.general.string == "ABCD-1234-EFGH")
        }
    }

    /// **A wrapped answer keeps its room over and under its words, and the rows of one card are equal** (the owner, 22
    /// November 2026: "text wrapping of the options does not look good"; `NeedOptions.option`): labels of 20, 60 and
    /// 110 characters draw rows of one, two and three lines, each 20 points or more higher than its words, and the row
    /// of the answer that the agent recommends is as high as the same words in a plain row. The bugs that this stops: a
    /// wrapped label that fills its row to the edges, as every row but the recommended one had it, and a row whose room
    /// goes with the next change of the badge.
    @MainActor @Test("a wrapped option keeps its room, and a recommended row is as high as a plain one",
                     .timeLimit(.minutes(1)))
    func aWrappedOptionKeepsItsRoom() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            try #require(store.pending == nil, "the simulator holds a request of its own")
            // the sample's hub names the answer that an agent recommends (owner feature need_recommended)
            store.startSample()
            defer { store.leaveSample() }
            await store.refresh()
            try #require(store.features.contains(NeedRecommended.feature))
            let labels = ["Refund all of it now", "Offer a voucher of 20% for the next order, and keep this one",
                          "Say no politely, and tell the customer that the window for a refund was 30 days, as the "
                            + "shop says in its terms"]
            try #require(labels.map(\.count) == [20, 60, 110])
            func need(recommended: String?) throws -> OwnerNeed {
                var fields: [String: Any] = ["id": 31, "by": "manager", "title": "Refund an order from 45 days ago?",
                                             "raised": 20, "todo": "", "options": labels,
                                             "why": "A customer asks for a refund 15 days after the 30-day window."]
                if let recommended { fields["recommended"] = recommended }
                return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: fields))
            }
            /// The height of the words alone, in the width that the row gives them: its own less 14 points at each side.
            func words(_ label: String, in row: CGRect) -> CGFloat {
                UIHostingController(rootView: Text(verbatim: label).font(.body))
                    .sizeThatFits(in: CGSize(width: row.width - 28, height: .greatestFiniteMagnitude)).height
            }

            // the card with no recommended answer, then with the agent's badge on the 20 characters, and on the 60
            var heights: [[CGFloat]] = []
            for recommended in [nil, labels[0], labels[1]] {
                let window = CardWindow(NeedCard(store: store, need: try need(recommended: recommended), header: true))
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(300))
                let rows = try labels.indices.map { try #require(window.frame(of: "need-option-31-\($0)")) }
                let line = words("A", in: rows[0])
                #expect(labels.indices.map { Int((words(labels[$0], in: rows[$0]) / line).rounded()) } == [1, 2, 3],
                        "the labels do not take one, two and three lines")
                for (label, row) in zip(labels, rows) {
                    #expect(row.height >= 44, "\(label.count) characters: a row of \(row.height) points")
                    #expect(row.height - words(label, in: row) >= 20,
                            "\(label.count) characters: \(row.height - words(label, in: row)) points of room in the row")
                }
                heights.append(rows.map(\.height))
            }
            // A row with the badge stands under the room for the badge's upper half, which VoiceOver's frame of the
            // row takes in: the one-line row of 44 points with the badge, less the same row without it. The two-line
            // row with the badge, less that room, is as high as the same words without it.
            let room = heights[1][0] - heights[0][0]
            #expect(abs(heights[2][1] - room - heights[0][1]) < 0.5,
                    "with the badge: \(heights[2][1] - room) points; the same words with none: \(heights[0][1])")
        }
    }
}

extension SampleFleetTests {
    /// **His press waits 5 seconds with Undo, and then goes once** (the owner's "Yes, 5 seconds (Recommended)" of 21
    /// November 2026; `MobileStore.hold`): the card stands folded with his answer and Undo, nothing reaches the Outbox or
    /// the hub for the 5 seconds, then the answer goes as a press went before, once, and Undo after it does nothing. The
    /// bugs that this stops: an answer that goes before he could take it back, one that never goes, and an Undo after
    /// the send that takes back an answer that went. **A press that waits for the hub after its 5 seconds keeps Undo
    /// and has no check** (the owner, 22 November 2026: "cards on the phone are left with Sending... and never
    /// complete"; `NeedCard.going`), and its Undo opens the card, and nothing of it reaches the hub. The bug that this
    /// stops: behind another answer on its way the folded card showed the check and no Undo, so it read "done" while
    /// nothing was saved or sent, and he could not take it back.
    @MainActor @Test("a press waits 5 seconds with Undo on its folded card, goes once, and keeps Undo while it waits",
                     .timeLimit(.minutes(1)))
    func aPressWaitsFiveSecondsThenGoesOnce() async throws {
        try await Self.withPictureHub { store, hub in
            let need = try #require(store.openNeeds.first { $0.id == 8 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let pressed = ContinuousClock.now
            #expect(window.press("need-option-8-1"))
            // folded, with Undo at the end of its line, and nothing saved or sent (the wait follows the card's
            // drawing, not a fixed time: a ship run under load draws it later)
            try await Self.until { window.parts.keys.contains("need-undo-8") }
            let parts = Set(window.parts.keys)
            #expect(parts.contains("need-undo-8") && !parts.contains("need-option-8-1"))
            #expect(store.pending == nil && hub.answers.isEmpty)
            try await Task.sleep(until: pressed + .milliseconds(4_700))
            #expect(store.pending == nil && hub.answers.isEmpty, "the answer went before its 5 seconds")
            try await Self.until { !hub.answers.isEmpty }
            #expect(ContinuousClock.now - pressed >= .seconds(5))
            let answer = try #require(hub.answers.first, "the answer never went")
            #expect(answer.path == "/ui/needs/8" && answer.body["choice"] as? Int == 1)
            // Undo after the send does nothing: no Undo stands, and nothing more goes
            try await Self.until { store.pending == nil && !store.sending }
            #expect(!window.parts.keys.contains("need-undo-8") && store.heldAnswer(to: 8) == nil)
            store.undo(needID: 8)
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.answers.count == 1)

            // behind another card's answer whose receipt the hub holds, his press on card 8 (open again: the hub's
            // reading still lists it) waits for the hub after its wait with Undo: its folded line keeps Undo and has
            // no check, and Undo opens the card, and nothing of it goes
            try await Self.until { window.parts.keys.contains("need-option-8-2") }
            try #require(window.parts.keys.contains("need-option-8-2"), "card 8 did not open again")
            store.answerWait = .milliseconds(100)
            hub.holdsAnswers = true
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.answers.count == 2 && store.sending }
            #expect(window.press("need-option-8-2"))
            try await Self.until { store.waitingPresses[8] != nil && window.parts.keys.contains("need-undo-8") }
            let waiting = try #require(NeedCard.going(need, store: store, given: store.givenAnswer(to: 8)))
            #expect(waiting.waits && !waiting.checks, "a press that waits for the hub shows the check")
            #expect(window.parts.keys.contains("need-undo-8"), "a press that waits for the hub has no Undo")
            #expect(window.press("need-undo-8"))
            try await Self.until { store.waitingPresses[8] == nil && window.parts.keys.contains("need-option-8-2") }
            #expect(store.waitingPresses[8] == nil && window.parts.keys.contains("need-option-8-2"),
                    "Undo did not open the card")
            hub.release()
            try await Self.until { store.pending == nil && !store.sending }
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.answers.map(\.path) == ["/ui/needs/8", "/ui/needs/7"], "the press that he took back went")
        }
    }

    /// **A card opens again when his answer goes after several changes of it in one frame** (`NeedCard.followAnswer`):
    /// SwiftUI drops a call of one onChange that comes after others in one frame (its log: "action tried to update
    /// multiple times per frame"). The bug that this stops: the call of the change that took his answer away was
    /// dropped, and the card that the hub still lists as open stood folded, with the line of an answer that no longer
    /// waits and no options (the ship runs of 24 and 25 November 2026, where `aPressWaitsFiveSecondsThenGoesOnce` found
    /// "card 8 did not open again"). Here five other options take the place of his first one, one after the other, and
    /// then Undo, each followed by three yields of the main actor: with the old fold, the card stood folded in each of
    /// three runs on 26 November 2026; with a draw of the window after each change, or with no pause, it opened.
    @MainActor @Test("a card opens again when his answer goes after several changes of it in one frame",
                     .timeLimit(.minutes(1)))
    func aCardOpensAgainAfterChangesInOneFrame() async throws {
        try await Self.withPictureHub { store, hub in
            // no hold may go to the hub while the first fold draws, also on a slow run: the check below says none went
            store.answerWait = .seconds(60)
            let need = try #require(store.openNeeds.first { $0.id == 8 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Self.until { window.parts.keys.contains("need-option-8-1") }
            store.hold(needID: 8, choice: 1)
            try await Self.until { window.parts.keys.contains("need-undo-8") }
            try #require(window.parts.keys.contains("need-undo-8"), "his press did not fold the card")
            for choice in [2, 0, 1, 2, 0] {
                store.hold(needID: 8, choice: choice)
                for _ in 0..<3 { await Task.yield() }
            }
            store.undo(needID: 8)
            for _ in 0..<3 { await Task.yield() }
            try await Self.until { window.parts.keys.contains("need-option-8-1") }
            #expect(window.parts.keys.contains("need-option-8-1") && !window.parts.keys.contains("need-undo-8"),
                    "the card stood folded after the changes of his answer in one frame")
            #expect(store.heldAnswer(to: 8) == nil && hub.answers.isEmpty)
        }
    }

    /// **The app's leave of the front sends every held answer at once, one after the other, and the end of their wait
    /// sends nothing more** (`MobileStore.setForeground`, `releaseHeldAnswers`): an app that ends in the background
    /// must not lose one. The bugs that this stops: an answer waits in memory and ends with the app; two answers that
    /// the leave lets go in one moment each see the store free, and the second ends with nothing sent and no sign (the
    /// review of 21 November 2026); the end of the wait sends one again.
    @MainActor @Test("the leave of the front sends each held answer at once, and each only once", .timeLimit(.minutes(1)))
    func theLeaveSendsAHeldAnswerOnce() async throws {
        try await Self.withPictureHub { store, hub in
            let pressed = ContinuousClock.now
            store.hold(needID: 8, choice: 2)
            store.hold(needID: 7, choice: 1)
            try #require(store.heldAnswer(to: 8) != nil && store.heldAnswer(to: 7) != nil && hub.answers.isEmpty)
            store.setForeground(false)
            try await Self.until { hub.answers.count == 2 }
            #expect(ContinuousClock.now - pressed < .seconds(3), "the leave did not send them at once")
            #expect(Set(hub.answers.map(\.path)) == ["/ui/needs/7", "/ui/needs/8"], "a held answer was lost")
            #expect(hub.answers.first { $0.path == "/ui/needs/8" }?.body["choice"] as? Int == 2)
            #expect(hub.answers.first { $0.path == "/ui/needs/7" }?.body["choice"] as? Int == 1)
            // past the end of their wait, and an Undo
            try await Task.sleep(until: pressed + .milliseconds(6_000))
            store.undo(needID: 8)
            try await Task.sleep(for: .milliseconds(300))
            #expect(hub.answers.count == 2, "an answer went twice")
            #expect(store.pending == nil && store.heldAnswer(to: 8) == nil && store.heldAnswer(to: 7) == nil)
        }
    }

    /// **Undo opens the card as it was, and nothing goes** (his "A click on Undo opens the card again as it was";
    /// `MobileStore.undo`): the options that he ticked are ticked again, his own words stay in his field, and the words
    /// that the agent's row put there give their place back to his. The bugs that this stops: an Undo that sends anyway,
    /// that leaves the card folded, that loses his ticks, or that leaves the agent's words in his field.
    @MainActor @Test("Undo opens the card as it was, with his ticks and his words, and nothing goes", .timeLimit(.minutes(1)))
    func undoOpensTheCardAsItWas() async throws {
        try await Self.withPictureHub { store, hub in
            store.answerWait = .seconds(2)
            defer {
                store.setAnswerDraft("", for: 7)
                store.setAnswerDraft("", for: 8)
            }
            let need = try #require(store.openNeeds.first { $0.id == 9 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let pressed = ContinuousClock.now
            #expect(window.press("need-tick-9-2") && window.press("need-tick-9-0"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.press("need-send-ticked-9"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("need-send-ticked-9"), "the card did not fold with his answer")
            #expect(window.press("need-undo-9"), "the folded card had no Undo")
            try await Task.sleep(for: .milliseconds(600))
            #expect(window.has("need-tick-9-0", .selected) && window.has("need-tick-9-2", .selected))
            #expect(!window.has("need-tick-9-1", .selected) && !window.parts.keys.contains("need-undo-9"))

            // his words with Send stay his; the agent's words give his own back
            store.setAnswerDraft("Use the blue one", for: 8)
            store.holdSend(needID: 8)
            try #require(store.heldAnswer(to: 8) != nil)
            store.undo(needID: 8)
            #expect(store.answerDraft(for: 8) == "Use the blue one")
            store.setAnswerDraft("My own words", for: 7)
            store.hold(needID: 7, words: "Orange, big words")
            #expect(store.answerDraft(for: 7) == "Orange, big words" && store.heldAnswer(to: 7) != nil)
            store.undo(needID: 7)
            #expect(store.answerDraft(for: 7) == "My own words")
            try await Task.sleep(until: pressed + .milliseconds(3_500))
            #expect(hub.answers.isEmpty && store.pending == nil, "an answer went after Undo")
        }
    }
}

/// **A hub with answered cards whose tasks stand as each of the marks** (owner features `need_marks` and
/// `task_controls`): card 21's task 41 works, card 22's task 42 works under his requested Pause, card 23 has no task,
/// card 24's task 44 holds his confirmed pause, and card 25's task 45 asks for his input. It takes a task's control with
/// the hub's receipt and holds that task from then on in its read, and it keeps each control's route and body, in order.
private final class MarkHub: LoopbackHub, @unchecked Sendable {
    /// How it takes a control: with its receipt, with the hub's refusal of a task that ended, by a cut connection
    /// before it takes it, as a hub that went away, or by a cut connection after it took it, as a receipt that was lost.
    /// A repeat of a control that it took gets its receipt, as the hub's record answers it.
    enum Mode { case answers, refuses, cuts, takesThenCuts }
    private var bodies: [(path: String, body: [String: Any])] = []
    private var paused: Set<Int> = []
    private var took: Set<String> = []
    private var taking = Mode.answers

    init() { super.init(label: "founderizer.check.mark-hub") }

    /// The controls that came, by route, in order, a refused and a cut one too.
    var controls: [(path: String, body: [String: Any])] { lock.withLock { bodies } }

    var mode: Mode {
        get { lock.withLock { taking } }
        set { lock.withLock { taking = newValue } }
    }

    override func answer(_ request: Request, on connection: NWConnection) {
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("GET", "/ui/mobile"):
            send(Self.reply(200, fleet()), on: connection)
        case ("POST", let path) where path.hasPrefix("/ui/tasks/") && path.hasSuffix("/control"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let task = Int(path.dropFirst("/ui/tasks/".count).dropLast("/control".count)) ?? 0
            let id = fields["request_id"] as? String ?? ""
            let mode = lock.withLock { () -> Mode in
                bodies.append((path, fields))
                if took.contains(id) { return .answers }
                if taking == .answers || taking == .takesThenCuts {
                    paused.insert(task)
                    took.insert(id)
                }
                return taking
            }
            if mode == .cuts || mode == .takesThenCuts { return connection.cancel() }
            if mode == .refuses {
                return send(Self.reply(409, #"{"error": "T-\#(task) is completed"}"#), on: connection)
            }
            let receipt: [String: Any] = [
                "ok": true, "request_id": fields["request_id"] as? String ?? "", "replayed": false, "changed": true,
                "client": request.headers["x-fleet-client"] ?? "",
                "hold": ["id": 90 + task, "task": task, "kind": "pause", "state": "requested", "attempt": 1],
            ]
            send(Self.reply(200, Self.text(receipt)), on: connection)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    private static func text(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The hub's compact read: the five answered cards of the agent atlas and their tasks.
    private func fleet() -> String {
        let held = lock.withLock { paused }
        func head(_ id: Int, state: String = "working") -> [String: Any] {
            ["id": id, "title": "Write the launch page \(id)", "state": state, "owner": "atlas", "requester": "manager",
             "attempt": 1, "created": 1_799_990_000, "started": 1_799_990_100, "last_activity": 1_799_999_900,
             "works": true]
        }
        func card(_ id: Int, task: Int?) -> [String: Any] {
            var card: [String: Any] = [
                "id": id, "by": "atlas", "title": "Which page goes first?", "why": "Two pages are ready.", "todo": "",
                "raised": 1_799_990_000 + id, "answer": "The pricing page", "answered": 1_799_995_000,
                "options": ["The pricing page", "The blog"], "chosen": 0,
            ]
            if let task { card["task"] = task }
            return card
        }
        let holds: [[String: Any]] = [["id": 1, "task": 42, "kind": "pause", "state": "requested", "attempt": 1],
                                      ["id": 2, "task": 44, "kind": "pause", "state": "stopped", "attempt": 1]]
            + held.sorted().map { ["id": 90 + $0, "task": $0, "kind": "pause", "state": "requested", "attempt": 1] }
        return Self.text([
            "schema_version": 1, "db": "gen-marks", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_marks", "task_controls"],
            "agents": [["name": "atlas", "role": "worker", "runtime": "claude", "open_tasks": 4, "usage": []]],
            "needs": [], "answered_needs": [card(21, task: 41), card(22, task: 42), card(23, task: nil),
                                            card(24, task: 44), card(25, task: 45)],
            "tasks": [head(41), head(42), head(44), head(45, state: "input-required")], "recent": [],
            "holds": holds, "outcomes": [],
        ] as [String: Any])
    }
}

extension SampleFleetTests {
    /// Runs `body` with a store that read the mark hub, and leaves nothing of it: no key, no reading, no request.
    @MainActor private static func withMarkHub(_ body: (MobileStore, MarkHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let hub = MarkHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-mark-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = Self.store(holder, named: "device-key-mark-check")
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && (store.snapshot?.answered_needs ?? []).count == 5)
                var failure: Error?
                do { try await body(store, hub) } catch { failure = error }
                for _ in 0..<60 where store.sending { try? await Task.sleep(for: .milliseconds(50)) }
                if let failure { throw failure }
            }
        }
    }

    /// **Pause stands at the end of an answered card's line only while its task works with nothing holding it, and its
    /// press sends the task's one Pause** (his "Both (Recommended)" of 21 November 2026; `MobileStore.pausable`,
    /// `pause(task:)`): the hub takes it from the phone's own key, and once the read has the hold, Pause goes. The bugs
    /// that this stops: a Pause on a task that his Pause or the hub holds already, or on a card with no task, and a Pause
    /// that goes twice or to another task.
    @MainActor @Test("Pause stands only while the card's task works, and sends one Pause of that task",
                     .timeLimit(.minutes(1)))
    func pauseStandsWhileTheTaskWorks() async throws {
        try await Self.withMarkHub { store, hub in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            #expect([21, 22, 23, 24, 25].map { cards[$0].flatMap(store.pausable) } == [41, nil, nil, nil, nil])
            for id in [22, 23, 24, 25] {
                let window = CardWindow(NeedCard(store: store, need: try #require(cards[id])))
                try await Task.sleep(for: .milliseconds(200))
                #expect(!window.actions(of: "need-folded-\(id)").contains("Pause"), "card \(id) offers Pause")
                window.close()
            }

            let window = CardWindow(NeedCard(store: store, need: try #require(cards[21])))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.perform("Pause", of: "need-folded-21"), "the working task's card has no Pause")
            try await Self.until { !hub.controls.isEmpty && store.pending == nil && !store.sending }
            let control = try #require(hub.controls.first)
            #expect(control.path == "/ui/tasks/41/control" && control.body["action"] as? String == "pause")
            // the read after the receipt holds the task: Pause goes, and nothing more is sent
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.actions(of: "need-folded-21").contains("Pause") && store.pausable(cards[21]!) == nil)
            #expect(hub.controls.count == 1)
        }
    }

    /// **A Pause that does not go says so on its card, and holds nothing behind it with no sign** (two reviews of 21
    /// November 2026): the hub's refusal (a task that ended between two reads) ends it by itself, so the phone writes
    /// again, and its card says why, in the phone's words, until his Discard gives the card its Pause back; one that the
    /// hub did not take goes nowhere by itself, and its card says "Not sent" with Try again, which sends the same
    /// request; one whose receipt was lost, while the reading has its task's hold, goes again by itself once and is
    /// confirmed. The bugs that this stops: a refused Pause that waits for a Discard that only Settings offers, or that
    /// ends with no words; an unsent Pause that goes by itself a day later; a Pause that did not go behind a card that
    /// looks as if nothing happened; a Try again that sends a second Pause.
    @MainActor @Test("a Pause that does not go says so on its card, and only a lost receipt goes again by itself",
                     .timeLimit(.minutes(1)))
    func aPauseThatDoesNotGoSaysSo() async throws {
        try await Self.withMarkHub { store, hub in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            let window = CardWindow(NeedCard(store: store, need: try #require(cards[21])))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))

            // refused: it leaves the Outbox by itself, its card says why with Discard, and Discard gives Pause back
            hub.mode = .refuses
            #expect(window.perform("Pause", of: "need-folded-21"))
            try await Self.until { !hub.controls.isEmpty && !store.sending }
            #expect(hub.controls.count == 1 && store.pending == nil && store.canWrite, "the refused Pause still waits")
            try await Task.sleep(for: .milliseconds(300))
            let refusal = window.parts["need-pause-words-21"]?.accessibilityLabel ?? ""
            #expect(refusal.contains("T-41 is completed"), "the refused Pause has no words on its card: \(refusal)")
            #expect(!window.actions(of: "need-folded-21").contains("Pause"))
            #expect(window.press("need-pause-discard-21"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.parts["need-pause-words-21"] == nil && window.actions(of: "need-folded-21").contains("Pause"))

            // not taken, and no hold in the reading: nothing goes by itself; its card says "Not sent" with Try again
            hub.mode = .cuts
            #expect(window.perform("Pause", of: "need-folded-21"))
            try await Self.until { hub.controls.count == 2 && !store.sending }
            await store.refresh()
            try await Task.sleep(for: .milliseconds(500))
            #expect(hub.controls.count == 2, "a Pause that the hub never took went again by itself")
            let waiting = try #require(store.pending, "the unsent Pause left the Outbox")
            #expect(window.parts["need-pause-words-21"]?.accessibilityLabel == "Not sent")
            #expect(!window.actions(of: "need-folded-21").contains("Pause"))
            hub.mode = .answers
            #expect(window.press("need-pause-retry-21"), "the unsent Pause's card has no Try again")
            try await Self.until { store.pending == nil && !store.sending }
            let sent = hub.controls.filter { $0.path == "/ui/tasks/41/control" }.compactMap { $0.body["request_id"] as? String }
            #expect(sent.count == 3 && sent.suffix(2).allSatisfy { $0 == waiting.requestID.uuidString.lowercased() },
                    "Try again sent a second Pause")

            // taken, and its receipt lost: the reading has the task's hold, so the same request goes again, once
            hub.mode = .takesThenCuts
            await store.pause(task: 45)
            try await Self.until { store.pending == nil && !store.sending }
            let replayed = hub.controls.filter { $0.path == "/ui/tasks/45/control" }.compactMap { $0.body["request_id"] as? String }
            #expect(replayed.count == 2 && Set(replayed).count == 1, "a lost receipt was not confirmed by its own request")
            #expect(store.pending == nil && store.canWrite)
        }
    }

    /// **A press of the mark opens the card's own task** (his "Yes, open task" and "Gray pause, as the row" of 21
    /// November 2026; `MobileStore.taskOpened`): the work mark, the orange mark and the gray mark of his pause, each its
    /// task's page, over the chat, and from Needs you in Tasks; the check opens nothing. The bugs that this stops: a press
    /// that opens another task (the card's own number, or another card's task), and a check that opens a task.
    @MainActor @Test("a press of the card's mark opens its own task, and the check opens none", .timeLimit(.minutes(1)))
    func theMarkOpensItsOwnTask() async throws {
        try await Self.withMarkHub { store, _ in
            let cards = Dictionary((store.snapshot?.answered_needs ?? []).map { ($0.id, $0) }) { first, _ in first }
            for (id, task) in [(21, 41), (24, 44), (25, 45), (22, nil), (23, nil)] as [(Int, Int?)] {
                store.chatRoute = [.chat("atlas")]
                let window = CardWindow(NeedCard(store: store, need: try #require(cards[id])))
                try await Task.sleep(for: .milliseconds(200))
                if let task {
                    #expect(window.perform("Open the task", of: "need-folded-\(id)"), "card \(id)'s mark opens nothing")
                    #expect(store.chatRoute == [.chat("atlas"), .task(task)], "card \(id) opened another task")
                } else {
                    #expect(!window.actions(of: "need-folded-\(id)").contains("Open the task"),
                            "card \(id)'s check opens a task")
                }
                window.close()
            }
            // on Needs you, in Tasks
            store.tab = .needs
            let window = CardWindow(NeedCard(store: store, need: try #require(cards[24]), header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.perform("Open the task", of: "need-folded-24"))
            #expect(store.tab == .tasks && store.taskRoute == [44])
        }
    }
}

/// **A hub that gives this phone a key for a code, and asks for it on each read and each answer** (owner devices,
/// MOBILE-APP.md 7): a request with no key gets the hub's refusal `device_key_required`, which is for good. Its read has
/// three open requests of the manager's, each with three options. While `holdsAnswers` is set it holds the receipt of
/// each answer until `letGo`. It keeps each answer's route and whether it came with the key, in order.
private final class KeyHub: LoopbackHub, @unchecked Sendable {
    static let key = "a-key-of-the-leave-check"
    private var bodies: [(path: String, keyed: Bool)] = []
    private var files: [Bool] = []
    private var holding = false
    private var held: [(connection: NWConnection, reply: Data)] = []

    init() { super.init(label: "founderizer.check.key-hub") }

    /// The answers that came, by route, in order, with whether each had the key.
    var answers: [(path: String, keyed: Bool)] { lock.withLock { bodies } }
    /// The files that came up, in order: whether each had the key.
    var uploads: [Bool] { lock.withLock { files } }
    /// The receipts that it holds now.
    var heldCount: Int { lock.withLock { held.count } }
    var holdsAnswers: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }

    /// The receipts that it holds go; it holds the next ones while `holdsAnswers` is set.
    func letGo() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }

    override func stop() {
        let left = lock.withLock { () -> [NWConnection] in
            defer { held = [] }
            return held.map(\.connection)
        }
        for connection in left { connection.cancel() }
        super.stop()
    }

    private static let refusal = #"{"error": "device key required", "auth": "device_key_required"}"#

    override func answer(_ request: Request, on connection: NWConnection) {
        let keyed = request.headers["authorization"] == "Bearer \(Self.key)"
        note("\(request.method) \(request.path)")
        switch (request.method, request.path) {
        case ("POST", "/ui/owner/enroll"):
            send(Self.reply(200, #"{"device": "phone-check", "label": "iPhone", "key": "\#(Self.key)"}"#), on: connection)
        case ("GET", "/ui/mobile"):
            send(keyed ? Self.reply(200, Self.fleet) : Self.reply(403, Self.refusal), on: connection)
        case ("POST", "/ui/attachments"):
            lock.withLock { files.append(keyed) }
            guard keyed else { return send(Self.reply(403, Self.refusal), on: connection) }
            let file: [String: Any] = ["id": 61, "name": request.headers["x-fleet-name"] ?? "file",
                                       "mime": request.headers["content-type"] ?? "", "size": request.body.count,
                                       "sha256": MessageAttachment.digest(request.body), "created": 1_800_000_200,
                                       "kept": NSNull()]
            send(Self.reply(200, (try? JSONSerialization.data(withJSONObject: file))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"), on: connection)
        case ("POST", let path) where path.hasPrefix("/ui/needs/"):
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let holds = lock.withLock { () -> Bool in
                bodies.append((path, keyed))
                return holding
            }
            guard keyed else { return send(Self.reply(403, Self.refusal), on: connection) }
            let receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "client": request.headers["x-fleet-client"] ?? "", "event_id": 101,
                                          "created": 1_800_000_100, "replayed": false]
            let reply = Self.reply(200, (try? JSONSerialization.data(withJSONObject: receipt))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}")
            let now = lock.withLock { () -> Bool in
                guard holds else { return true }
                held.append((connection, reply))
                return false
            }
            if now { send(reply, on: connection) }
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    /// The hub's compact read: requests 7, 8 and 9 of the manager's.
    private static let fleet: String = {
        func card(_ id: Int) -> [String: Any] {
            ["id": id, "by": "manager", "title": "Which day goes the newsletter?", "why": "The draft is ready.", "todo": "",
             "raised": 1_799_999_000 + id, "answer": NSNull(), "answered": NSNull(),
             "options": ["Monday", "Tuesday", "Friday"]]
        }
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-key", "time": 1_800_000_000, "ui_features": ["mobile", "need_options"],
            "agents": [], "needs": [card(7), card(8), card(9)], "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }()
}

extension SampleFleetTests {
    /// **Answers that wait as the app leaves the front go with this phone's key, the key goes once each of them started,
    /// and no answer ever goes without it** (`MobileStore.lockKeyAtTheLeave`, `canWrite`; the review of 21 November
    /// 2026). A request with no key is refused for good, and the phone then asks to be enrolled again. The bugs that this
    /// stops: the key kept only for the first answer, so the second goes later with none; a press that waits and goes
    /// with no key once the key is locked; the key kept in memory until each send's receipt came.
    @MainActor @Test("answers that wait at the leave go with the key, which goes once they started, and none goes without it",
                     .timeLimit(.minutes(1)))
    func answersAtTheLeaveGoWithTheKey() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = KeyHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own: the key of an enrolled phone is never touched.
                let holder = DeviceKey(account: "device-key-leave-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = Self.store(holder, named: "device-key-leave-check")
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: Self.support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                await store.openLink(try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345")))
                try #require(store.keyState == .ready && store.canWrite && store.openNeeds.map(\.id) == [9, 8, 7])

                // two answers wait at the leave, and the hub holds each receipt: the second waits behind the first,
                // with the key in hand for it
                hub.holdsAnswers = true
                store.hold(needID: 7, choice: 0)
                store.hold(needID: 8, choice: 1)
                store.setForeground(false)
                store.lockKeyAtTheLeave()
                try await Self.until { hub.answers.count == 1 }
                #expect(store.keyState == .ready && store.waitingPresses[8] != nil, "the key went before the second answer")
                hub.letGo()
                try await Self.until { hub.answers.count == 2 }
                // the second started with the key: the key goes, while its receipt is still on its way (within a second:
                // the client's own limit of 15 seconds would end that send, and the key with it)
                for _ in 0..<50 where store.keyState != .locked { try await Task.sleep(for: .milliseconds(20)) }
                #expect(store.keyState == .locked && hub.heldCount == 1, "the key stayed until the sends ended")
                // iOS's time in the background lasts until that receipt has come, and ends with it
                #expect(store.holdsBackgroundTime, "the background time ended before the last answer's receipt")
                hub.holdsAnswers = false
                hub.letGo()
                try await Self.until { !store.sending && store.pending == nil }
                for _ in 0..<50 where store.holdsBackgroundTime { try await Task.sleep(for: .milliseconds(20)) }
                #expect(!store.holdsBackgroundTime, "the background time outlived the sends")

                // with the key locked, the page says so, though its reading is current: every write waits for the key
                #expect(store.keyWords != nil && store.unavailableWords == store.keyWords,
                        "a write waits for the key with no reason on the page")
                // an answer waits for it and nothing goes; with the key back (a new code here, Face ID in the app) it
                // goes
                store.hold(needID: 9, choice: 2)
                store.releaseHeld(9)
                try await Task.sleep(for: .milliseconds(800))
                #expect(hub.answers.count == 2 && store.waitingPresses[9] != nil, "an answer went with the key locked")
                #expect(await store.enroll(code: "ABCD-2345") == nil)
                try await Self.until { hub.answers.count == 3 && !store.sending }
                #expect(hub.answers.map(\.path) == ["/ui/needs/7", "/ui/needs/8", "/ui/needs/9"])
                #expect(hub.answers.filter { !$0.keyed }.isEmpty, "an answer went without the key")
                #expect(!store.needsEnrollment)
            }
        }
    }

    /// Runs `body` with a store that this hub enrolled with a key of the check's own, and leaves nothing of it: no
    /// key, no reading, no request, no file.
    @MainActor private static func withKeyHub(_ body: (MobileStore, KeyHub) async throws -> Void) async throws {
        try await withoutHub {
            try await keepingReadings {
                let staged = UserDefaults.standard.object(forKey: "stagedFiles")
                defer {
                    if let staged { UserDefaults.standard.set(staged, forKey: "stagedFiles") }
                    else { UserDefaults.standard.removeObject(forKey: "stagedFiles") }
                }
                let hub = KeyHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-keyhub-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = Self.store(holder, named: "device-key-keyhub-check")
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                await store.openLink(try #require(URL(string: "fleet://enroll?hub=\(address)&code=ABCD-2345")))
                try #require(store.keyState == .ready && store.canWrite && store.openNeeds.map(\.id) == [9, 8, 7])
                try await body(store, hub)
            }
        }
    }

    /// **Where iOS gives no time in the background, the first answer that waits goes into the Outbox and is not sent**
    /// (`MobileStore.keepFirstUnsent`; the review of 21 November 2026): an end of the app there does not lose it, and at
    /// the return his Try again sends it, with the key. The bugs that this stops: with no time to send, the first answer
    /// waits in memory only and goes with the app; it goes with no key.
    @MainActor @Test("with no background time the first held answer waits in the Outbox, unsent, for Try again",
                     .timeLimit(.minutes(1)))
    func noBackgroundTimeKeepsTheFirstAnswer() async throws {
        try await Self.withKeyHub { store, hub in
            store.backgroundTimeRefused = true
            store.hold(needID: 7, choice: 0)
            store.hold(needID: 8, choice: 1)
            store.setForeground(false)
            store.lockKeyAtTheLeave()
            try await Task.sleep(for: .milliseconds(500))
            let kept = try #require(store.pending, "the first answer is only in memory")
            #expect(kept.needID == 7 && kept.choice == 0 && kept.refusal == nil && !store.sending && hub.answers.isEmpty)
            #expect(store.keyState == .locked && store.waitingPresses[8] != nil)
            // a start of the app finds it
            #expect(MobileStore(deviceKey: DeviceKey(account: "device-key-keyhub-check")).pending?.requestID == kept.requestID)
            // the return, with the key: it says "Not sent", and his Try again sends it, then the one behind it goes
            #expect(await store.enroll(code: "ABCD-2345") == nil)
            #expect(store.waitsUnsent(for: 7) && store.canRetry)
            await store.retry()
            try await Self.until { hub.answers.count == 2 && !store.sending && store.pending == nil }
            #expect(hub.answers.map(\.path) == ["/ui/needs/7", "/ui/needs/8"])
            #expect(hub.answers.filter { !$0.keyed }.isEmpty, "an answer went without the key")
        }
    }

    /// **A file waits for this phone's key, and goes up with it** (`MobileStore.upload`; the review of 21 November
    /// 2026). The bug that this stops: a file that he picked, or sent again, goes up with no key, the hub refuses the
    /// phone for good, and its row says to add this phone again with a new code.
    @MainActor @Test("a file waits for this phone's key, and goes up with it", .timeLimit(.minutes(1)))
    func aFileWaitsForTheKey() async throws {
        try await Self.withKeyHub { store, hub in
            let composer = MobileStore.stageKey(need: 7)
            defer { for file in store.stagedFiles(for: composer) { store.removeStaged(file, for: composer) } }
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            store.lockKey()
            let staging = Task { await store.stage(picture, name: "plan.png", mime: "image/png", for: composer) }
            try await Task.sleep(for: .milliseconds(800))
            #expect(hub.uploads.isEmpty && store.readyFiles(for: composer).isEmpty, "a file went up with the key locked")
            #expect(await store.enroll(code: "ABCD-2345") == nil)
            await staging.value
            #expect(hub.uploads == [true], "the file did not go up with the key")
            #expect(store.readyFiles(for: composer) == [61] && store.authProblem == nil)
        }
    }
}

/// **A hub of two open requests with options, 7 and 8, both the manager's** (the answers of a phone that stayed at
/// "Sending…": the owner, 22 November 2026): it takes an answer with the hub's receipt, cuts the connection before it
/// takes it, as a hub that went away, or takes it and then cuts the connection, as an answer whose receipt was lost on
/// its way back. A repeat of a request that it took gets that request's first result, as the hub's own record answers
/// it. An item whose answer it took is answered in its read, and the answer is a message with the request's number in
/// the manager's chat, as the hub writes it; an item that another hand answered (`answerElsewhere`) has that hand's
/// message there. Or it refuses the answer for good. It takes his message under a card and a task's Pause with their
/// receipts, as commands. `database` names its generation, and it fails the next `failsReads` reads of the fleet with
/// 502, as a proxy whose hub went away: a cut connection would not do, because the system sends a read again by itself
/// when its connection closes before any answer, and that second read worked. It keeps the route of each answer that
/// came, a cut or refused one too, and the item of each answer that it took, in order, the route of each command, and
/// the words of each answer and message. Request 9 asks for a key: it takes his words about it (Needs clarification,
/// on its own route), which close it. With `recommendsWords`, request 8 has no options and the words that its agent
/// recommends (owner feature `need_recommended`). `cutsFirst`: it cuts the first send of each request before it takes
/// it, and takes that request when it comes again. While `holdsReceipts` is set it holds each receipt of an answer
/// until `letGo`. With `listsManager`, its read lists the manager, whose chat takes a message: it cuts each one before
/// it takes it, and keeps their count.
private final class AnswerHub: LoopbackHub, @unchecked Sendable {
    enum Mode { case takes, cutsBefore, cutsAfter, cutsFirst, refuses }
    private var answering = Mode.takes
    private var wordsOnEight = false
    private var managerListed = false
    private var messageCount = 0
    private var requestIDs: [String] = []
    private var holding = false
    private var held: [(connection: NWConnection, reply: Data)] = []
    private var generation = "gen-answers-1"
    private var routes: [String] = []
    private var took: [(item: Int, request: String)] = []
    private var elsewhere: [Int] = []
    private var readsToFail = 0
    private var commandRoutes: [String] = []
    private var sentWords: [String] = []

    init() { super.init(label: "founderizer.check.answer-hub") }

    var mode: Mode {
        get { lock.withLock { answering } }
        set { lock.withLock { answering = newValue } }
    }
    var database: String {
        get { lock.withLock { generation } }
        set { lock.withLock { generation = newValue } }
    }
    var failsReads: Int {
        get { lock.withLock { readsToFail } }
        set { lock.withLock { readsToFail = newValue } }
    }
    var recommendsWords: Bool {
        get { lock.withLock { wordsOnEight } }
        set { lock.withLock { wordsOnEight = newValue } }
    }
    var listsManager: Bool {
        get { lock.withLock { managerListed } }
        set { lock.withLock { managerListed = newValue } }
    }
    /// The chat messages that came, all cut.
    var messageTries: Int { lock.withLock { messageCount } }
    /// The route of each answer that came, a cut one too, in order.
    var tries: [String] { lock.withLock { routes } }
    /// The request number of each answer that came, a cut one too, in order.
    var tryIDs: [String] { lock.withLock { requestIDs } }
    var holdsReceipts: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    /// The receipts that it holds go, and it holds no more.
    func letGo() {
        let going = lock.withLock { () -> [(connection: NWConnection, reply: Data)] in
            holding = false
            defer { held = [] }
            return held
        }
        for (connection, reply) in going { send(reply, on: connection) }
    }
    /// The item of each answer that it took, in order.
    var taken: [Int] { lock.withLock { took.map(\.item) } }
    /// The route of each message under a card and each Pause that it took, in order.
    var commands: [String] { lock.withLock { commandRoutes } }
    /// The words of each answer, message under a card and words about a key that came, in order.
    var words: [String] { lock.withLock { sentWords } }
    /// Another hand answers the item: the Mac, the owner tools, the manager.
    func answerElsewhere(_ item: Int) { lock.withLock { elsewhere.append(item) } }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        note(route)
        switch route {
        case "GET /ui/mobile":
            let fails = lock.withLock { () -> Bool in
                defer { readsToFail = max(0, readsToFail - 1) }
                return readsToFail > 0
            }
            if fails { return send(Self.reply(502, #"{"error": "bad gateway"}"#), on: connection) }
            send(Self.reply(200, fleet()), on: connection)
        case "GET /ui/mobile/chat/manager":
            send(Self.reply(200, chat()), on: connection)
        case "POST /ui/messages":
            lock.withLock { messageCount += 1 }
            connection.cancel()
        case "POST /ui/needs/7/talk", "POST /ui/needs/8/talk", "POST /ui/tasks/41/control":
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            lock.withLock {
                commandRoutes.append(request.path)
                if let text = fields["text"] as? String { sentWords.append(text) }
            }
            var receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "client": request.headers["x-fleet-client"] ?? "", "replayed": false]
            if request.path.hasSuffix("/talk") {
                receipt["need"] = Int(request.path.split(separator: "/")[2]) ?? 0
                receipt["talk"] = [["who": "owner", "text": fields["text"] as? String ?? "", "ts": 1_800_000_060]]
            } else {
                receipt["changed"] = true
                receipt["hold"] = ["id": 91, "task": 41, "kind": "pause", "state": "requested", "attempt": 1]
            }
            send(Self.reply(200, Self.json(receipt)), on: connection)
        case "POST /ui/needs/7", "POST /ui/needs/8", "POST /ui/needs/9/secret":
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let item = Int(request.path.split(separator: "/")[2]) ?? 0
            let id = fields["request_id"] as? String ?? ""
            let (takes, known, holds) = lock.withLock { () -> (Bool, Bool, Bool) in
                routes.append(request.path)
                let again = requestIDs.contains(id)
                requestIDs.append(id)
                if let words = fields["answer"] as? String ?? fields["clarify"] as? String { sentWords.append(words) }
                let known = took.contains { $0.request == id }
                let takes = answering == .takes || (answering == .cutsFirst && again)
                if !known && (takes || answering == .cutsAfter) { took.append((item, id)) }
                return (known || takes, known, holding)
            }
            if !known && mode == .refuses {
                return send(Self.reply(409, #"{"error": "this request takes no answer now"}"#), on: connection)
            }
            guard takes else { return connection.cancel() }
            let receipt: [String: Any] = ["ok": true, "request_id": id, "event_id": 100 + item, "replayed": known,
                                          "client": request.headers["x-fleet-client"] ?? "", "created": 1_800_000_100]
            let reply = Self.reply(200, Self.json(receipt))
            if holds {
                let kept = lock.withLock { () -> Bool in
                    // (a let go between the hold's read and this line lets it go now)
                    guard holding else { return false }
                    held.append((connection, reply))
                    return true
                }
                if kept { return }
            }
            send(reply, on: connection)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The manager's chat: the message of each answer, by its request's number, oldest first.
    private func chat() -> String {
        let (database, answers) = lock.withLock {
            (generation, took.map { ($0.item, $0.request) } + elsewhere.map { ($0, UUID().uuidString.lowercased()) })
        }
        let items: [[String: Any]] = answers.enumerated().map { index, answer in
            ["kind": "message", "ts": 1_800_000_100 + index, "id": answer.1, "text": "Answered", "attachments": [],
             "client": "founderizer-swift/0.1", "answer_to": answer.0]
        }
        return Self.json(["db": database, "agent": "manager", "items": items, "cursor": 1_800_000_200] as [String: Any])
    }

    /// The hub's compact read: the requests open in it, and answered the ones whose answer it took or another hand
    /// gave.
    private func fleet() -> String {
        let (database, answered, words, manager) = lock.withLock {
            (generation, Set(took.map(\.item) + elsewhere), wordsOnEight, managerListed)
        }
        func card(_ id: Int) -> [String: Any] {
            let options = id == 7 ? ["Refund it", "Offer a 20% voucher", "Say no, politely"]
                : words ? [] : ["Send it on Monday", "Show me the email first"]
            return ["id": id, "by": "manager", "raised": 1_799_999_000 + id, "todo": "", "options": options,
                    "recommended": id == 8 && words ? "Send it on Monday at 9:00" : NSNull(),
                    "title": id == 7 ? "Refund an order from 45 days ago?" : "Send the spring sale email on Monday?",
                    "why": id == 7 ? "A customer asks for a refund 15 days after the 30-day window."
                        : "The email is written and the list is ready.",
                    "answer": answered.contains(id) ? options.first ?? "Answered" : NSNull(), "clarify": true,
                    "answered": answered.contains(id) ? 1_800_000_100 : NSNull()]
        }
        // request 9 asks for a key, which only the Mac's secure form saves; his words about it close it
        func keyCard() -> [String: Any] {
            ["id": 9, "by": "manager", "kind": "secret", "raised": 1_799_999_009, "todo": "",
             "title": "Enter the API key SHOP_MAIL_KEY for mail.example.com", "why": "The shop's mail key ends today.",
             "answer": answered.contains(9) ? "Answered" : NSNull(),
             "answered": answered.contains(9) ? 1_800_000_100 : NSNull()]
        }
        let open = [7, 8].filter { !answered.contains($0) }.map(card) + (answered.contains(9) ? [] : [keyCard()])
        return Self.json([
            "schema_version": 1, "db": database, "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options", "need_clarify", "task_controls", "secret_clarify_phone"]
                + (words ? [NeedRecommended.feature] : []),
            "agents": manager ? [["name": "manager", "role": "manager", "runtime": "claude", "open_tasks": 0,
                                  "usage": []] as [String: Any]] : [],
            "needs": open,
            "answered_needs": [7, 8].filter(answered.contains).map(card) + (answered.contains(9) ? [keyCard()] : []),
            "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ] as [String: Any])
    }
}

extension SampleFleetTests {
    /// Runs `body` with a store that read the answer hub, and leaves nothing of it: no key, no reading, no request.
    @MainActor private static func withAnswerHub(_ body: (MobileStore, AnswerHub) async throws -> Void) async throws {
        // the generation of the drafts that the check's reads record goes with it: a later check's drafts stay
        let place = UserDefaults.standard.object(forKey: "answerDraftsPlace")
        defer {
            if let place { UserDefaults.standard.set(place, forKey: "answerDraftsPlace") }
            else { UserDefaults.standard.removeObject(forKey: "answerDraftsPlace") }
        }
        try await withoutHub {
            try await keepingReadings {
                let hub = AnswerHub()
                defer { hub.stop() }
                let address = try await hub.start()
                // A key of the check's own, which holds none: the reads go with no key, and an enrolled phone's key is
                // never touched.
                let holder = DeviceKey(account: "device-key-answer-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                // whatever this check leaves in the Outbox goes with it
                defer {
                    if let left = store.pending {
                        try? Outbox(file: support.appendingPathComponent("pending.json")).clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && store.openNeeds.map(\.id).sorted() == [7, 8, 9])
                var failure: Error?
                do { try await body(store, hub) } catch { failure = error }
                // a press that still waits goes to this hub, or drops, before the check cleans up
                for _ in 0..<60 where !store.waitingPresses.isEmpty || store.sending {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let failure { throw failure }
            }
        }
    }

    /// **A request of another generation leaves at the first read of the new one** (the owner, 22 November 2026:
    /// "cards on the phone are left with Sending... and never complete"; `MobileStore.readSnapshot`): an answer whose
    /// send the hub cut waits unsent in the Outbox; the hub's next read has a new generation; that read takes the
    /// request off the phone, nothing of it goes, and a press then goes. The bug that this stops: the request of the
    /// gone generation stayed for ever, also after a start of the app; it can never go (it goes only to its own),
    /// Settings offered no control for it, and every later answer of the phone waited behind it under "Sending…".
    @MainActor @Test("a request of another generation leaves at the first read of the new one, and a press goes",
                     .timeLimit(.minutes(1)))
    func aRequestOfAnotherGenerationLeaves() async throws {
        try await Self.withAnswerHub { store, hub in
            // (a send that got no answer goes again by itself, `MobileStore.resends`: here the first send is the last)
            store.resends = 0
            hub.mode = .cutsBefore
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.tries.count == 1 && !store.sending }
            let cut = try #require(store.pending, "the cut answer is not in the Outbox")
            try #require(cut.needID == 7 && cut.refusal == nil && !store.canWrite)

            // the hub's new generation: its first read takes the request off the phone
            hub.mode = .takes
            hub.database = "gen-answers-2"
            await store.refresh()
            try #require(store.snapshot?.db == "gen-answers-2" && store.readError == nil)
            #expect(store.pending == nil, "the request of the old generation stays")
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)

            // and a press goes
            store.press(needID: 8, choice: 1)
            try await Self.until { !hub.taken.isEmpty && store.pending == nil && !store.sending }
            #expect(hub.taken == [8] && hub.tries == ["/ui/needs/7", "/ui/needs/8"])
        }
    }

    /// **A read finds an answer whose receipt was lost, and clears one that another hand overtook** (the owner, 22
    /// November 2026: "cards on the phone are left with Sending... and never complete"; `MobileStore.confirmAnswer`):
    /// the hub takes card 7's answer and cuts the connection; the next read no longer lists 7 as open and has the
    /// request's number in the manager's chat, so the request ends as its receipt would have ended it, sent once. The
    /// hub cuts card 8's answer before it takes it, and another hand answers card 8: the next read clears the request,
    /// and nothing of it goes again. **With the sends that go again by itself** (`MobileStore.resend`): the read at the
    /// end of card 7's send no longer lists 7 as open, so the answer does not go again before the next read confirms
    /// it. The bugs that this stops: an answer whose receipt was lost, or one that the Mac or a notification
    /// overtook, stayed in the Outbox, and every later answer waited behind it under "Sending…"; an answer whose item
    /// closed went again by itself.
    @MainActor @Test("a read finds an answer whose receipt was lost, and clears one that another hand overtook",
                     .timeLimit(.minutes(1)))
    func aReadFindsAnAnswerWhoseReceiptWasLost() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.mode = .cutsAfter
            store.press(needID: 7, choice: 1)
            // (the read at the end of the send comes while it still holds `sending`: the next read is the one)
            try await Self.until { !hub.tries.isEmpty && !store.sending }
            try #require(store.pending?.needID == 7 && store.pending?.refusal == nil, "the cut answer is not kept")
            await store.refresh()
            #expect(store.pending == nil, "the answer whose receipt was lost stays in the Outbox")
            #expect(hub.tries == ["/ui/needs/7"] && hub.taken == [7])
            #expect(!store.openNeeds.contains { $0.id == 7 })

            // (the read at the end of card 8's send fails, so nothing goes again before another hand answers it)
            hub.mode = .cutsBefore
            hub.failsReads = 1
            store.press(needID: 8, choice: 0)
            try await Self.until { hub.tries.count == 2 && !store.sending }
            try #require(store.pending?.needID == 8 && store.pending?.refusal == nil, "the cut answer is not kept")
            hub.answerElsewhere(8)
            hub.mode = .takes
            await store.refresh()
            #expect(store.pending == nil, "the answer that another hand overtook stays in the Outbox")
            #expect(hub.tries == ["/ui/needs/7", "/ui/needs/8"] && hub.taken == [7])
        }
    }

    /// **The answer that the hub took stays taken until a read that worked** (the owner, 22 November 2026: "cards on
    /// the phone are left with Sending... and never complete"; `MobileStore.decideTaken`): the hub gives the receipt of
    /// card 7's answer and fails the read after it; the card keeps his answer meanwhile, and the next read that works,
    /// which has 7 answered, folds it away. The bug that this stops: the failed read decided, the card stood open again
    /// with no sign, and a second press met the hub's "already answered".
    @MainActor @Test("the answer that the hub took stays taken until a read that worked", .timeLimit(.minutes(1)))
    func aTakenAnswerStaysUntilAReadThatWorked() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.failsReads = 1
            store.press(needID: 7, choice: 2)
            try await Self.until { hub.taken == [7] && store.pending == nil && !store.sending }
            try #require(hub.taken == [7] && store.readError != nil, "the read after the receipt did not fail")
            #expect(store.givenAnswer(to: 7) == .option(2), "the card stands open again after a read that failed")

            await store.refresh()
            #expect(store.readError == nil && !store.openNeeds.contains { $0.id == 7 })
            #expect(hub.tries == ["/ui/needs/7"])
        }
    }

    /// **A press that waits behind an answer that did not go says so, with Try again** (the owner, 22 November 2026:
    /// "cards on the phone are left with Sending... and never complete"; `NeedFooter.stoppedAhead`): the hub cuts card
    /// 7's answer and still lists 7 as open; a press on card 8 waits behind it, and the line under card 8 says "Not
    /// sent" with Try again, not "Sending…"; its folded line keeps the ring of a press that waits (F10, B1; VoiceOver
    /// reads it "Sending"); Try again sends card 7's request, and card 8's answer goes after it, each once. The bug
    /// that this stops: card 8 said "Sending…" with no end, no reason and nothing to press, while the request that
    /// held it waited for a Try again that only card 7 or Settings offered.
    @MainActor @Test("a press behind an answer that did not go says Not sent with Try again, and goes after it",
                     .timeLimit(.minutes(1)))
    func aPressBehindAStoppedAnswerSaysSo() async throws {
        try await Self.withAnswerHub { store, hub in
            store.answerWait = .milliseconds(100)
            // (a send that got no answer goes again by itself, `MobileStore.resends`: here the first send is the last)
            store.resends = 0
            hub.mode = .cutsBefore
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.tries.count == 1 && !store.sending }
            try #require(store.pending?.needID == 7 && store.pending?.refusal == nil && store.canRetry)

            hub.mode = .takes
            let need = try #require(store.openNeeds.first { $0.id == 8 })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("need-option-8-1"))
            try await Self.until { store.waitingPresses[8] != nil }
            // past the second after which "Sending…" comes under a card
            try await Task.sleep(for: .milliseconds(1_300))
            let words = window.labels
            #expect(words.contains { $0.contains("Not sent") } && words.contains { $0.contains("Try again") },
                    "the card of a press that waits behind an answer that did not go does not say so")
            // (the words "Sending…" under the card; the ring's own VoiceOver word is "Sending", with no "…")
            #expect(!words.contains { $0.contains("Sending…") }, "the card says Sending… while nothing goes")
            #expect(window.parts.keys.contains("need-ring-8"), "the press that waits has no ring")
            #expect(window.parts.keys.contains("waiting-answer"))

            await store.retry()
            try await Self.until { hub.taken.count == 2 && store.pending == nil && !store.sending }
            #expect(hub.taken == [7, 8] && hub.tries == ["/ui/needs/7", "/ui/needs/7", "/ui/needs/8"])
        }
    }

    /// **An answer on its way has the ring in the check's place, and no word; the hub's receipt puts the check there**
    /// (F10, B1: the owner's "Yes, as drawn" of 22 November 2026 to "a ring that turns, then the check, with no word";
    /// `NeedCard.going`, `SendingRing`): while the hub holds the receipt of card 7's answer, its folded line has the
    /// ring, which VoiceOver reads as "Sending", and no Undo, and nothing under the card says "Sending…", past the
    /// second after which those words came; a press on card 8 that waits behind it has the ring and Undo, since nothing
    /// of it left the phone. At the receipt the ring goes and the check stands. The bugs that this stops: an answer on
    /// its way with no sign, or with the words that he called bad, and a check that says "done" before the hub had it.
    @MainActor @Test("an answer on its way has the ring and no word, and the check once the hub took it",
                     .timeLimit(.minutes(1)))
    func anAnswerOnItsWayHasTheRingThenTheCheck() async throws {
        try await Self.withAnswerHub { store, hub in
            let seven = try #require(store.openNeeds.first { $0.id == 7 })
            let eight = try #require(store.openNeeds.first { $0.id == 8 })
            let window = CardWindow(NeedCard(store: store, need: seven, header: true))
            defer { window.close() }
            let other = CardWindow(NeedCard(store: store, need: eight, header: true))
            defer { other.close() }
            try await Task.sleep(for: .milliseconds(300))
            store.answerWait = .milliseconds(100)
            hub.holdsReceipts = true
            #expect(window.press("need-option-7-0"))
            try await Self.until { hub.tries.count == 1 && store.sending }
            #expect(other.press("need-option-8-1"))
            try await Self.until { store.waitingPresses[8] != nil }
            // past the second after which "Sending…" stood under the card
            try await Task.sleep(for: .milliseconds(1_300))
            #expect(window.parts["need-ring-7"]?.accessibilityLabel == "Sending", "an answer on its way has no ring")
            #expect(!window.parts.keys.contains("need-undo-7"), "an answer that left the phone has Undo")
            #expect(!window.labels.contains { $0.contains("Sending…") } && window.parts["waiting-answer"] == nil,
                    "words stand under the card of an answer on its way")
            #expect(NeedCard.going(seven, store: store, given: store.givenAnswer(to: 7))?.checks == false,
                    "the check stands before the hub took the answer")
            #expect(other.parts.keys.contains("need-ring-8") && other.parts.keys.contains("need-undo-8"),
                    "a press that waits for the hub has no ring or no Undo")

            hub.letGo()
            try await Self.until { hub.taken == [7, 8] && store.pending == nil && !store.sending }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("need-ring-7"), "the ring stays once the hub took the answer")
            #expect(NeedCard.going(seven, store: store, given: store.givenAnswer(to: 7))?.checks == true,
                    "the answer that the hub took has no check")
        }
    }

    /// **An answer whose send got no answer goes again by itself, at most two more times, while the app stays in
    /// front** (F10, C1: the owner's "Yes" of 22 November 2026; `MobileStore.resend`): the hub cuts card 7's first send
    /// and fails the read after it; nothing goes until a read works, the card keeps its ring meanwhile and does not
    /// say "Not sent", and then the same request goes once more and the hub takes it. A hub that cuts every send of
    /// card 8 gets three, and then the card says "Not sent". After a leave of the front a read that works sends
    /// nothing by itself, and his Try again still sends the same request. **A chat message is no answer**: one that
    /// got no answer waits for his Try again (his yes was for an answer). The bugs that this stops: a cut send that
    /// waited for his Try again while he looked at the card; a send that goes again with no end, or a new number that
    /// the hub would count twice; one that goes again after the app left the front; a chat message sent again with
    /// no yes of his.
    @MainActor @Test("a send that got no answer goes again after a read that worked, at most twice, only in front",
                     .timeLimit(.minutes(1)))
    func aSendThatGotNoAnswerGoesAgainByItself() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.mode = .cutsFirst
            hub.failsReads = 1
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.tries.count == 1 && !store.sending }
            try await Task.sleep(for: .milliseconds(300))
            #expect(hub.tries.count == 1, "it went again after a read that failed")
            let seven = try #require(store.openNeeds.first { $0.id == 7 })
            #expect(NeedCard.going(seven, store: store, given: store.givenAnswer(to: 7))?.mark == .ring
                    && !store.waitsUnsent(for: 7), "the card says Not sent while its answer goes again")
            await store.refresh()
            try await Self.until { hub.taken == [7] && store.pending == nil && !store.sending }
            #expect(hub.tries == ["/ui/needs/7", "/ui/needs/7"] && Set(hub.tryIDs).count == 1)

            // at most two more times
            hub.mode = .cutsBefore
            store.press(needID: 8, choice: 1)
            try await Self.until { hub.tries.count == 5 && !store.sending }
            try await Task.sleep(for: .milliseconds(400))
            await store.refresh()
            try await Task.sleep(for: .milliseconds(400))
            #expect(hub.tries.count == 5, "card 8's answer went \(hub.tries.count - 2) times")
            #expect(Set(hub.tryIDs.suffix(3)).count == 1, "it went again with a new number")
            #expect(store.waitsUnsent(for: 8), "the card does not say Not sent after its third send")

            // his Try again is a send of his own; after a leave of the front nothing goes by itself
            hub.failsReads = 1
            await store.retry()
            #expect(hub.tries.count == 6 && store.resend != nil)
            store.setForeground(false)
            store.setForeground(true)
            #expect(store.resend == nil && store.waitsUnsent(for: 8))
            await store.refresh()
            try await Task.sleep(for: .milliseconds(400))
            #expect(hub.tries.count == 6, "it went by itself after a leave of the front")
            hub.mode = .takes
            await store.retry()
            try await Self.until { store.pending == nil && !store.sending }
            #expect(hub.taken == [7, 8] && Set(hub.tryIDs.suffix(5)).count == 1)

            // a chat message that got no answer is not sent again by itself
            let drafts = UserDefaults.standard.object(forKey: "agentDrafts")
            defer {
                if let drafts { UserDefaults.standard.set(drafts, forKey: "agentDrafts") }
                else { UserDefaults.standard.removeObject(forKey: "agentDrafts") }
            }
            hub.listsManager = true
            await store.refresh()
            try #require(store.canWrite && store.canChat(with: "manager"), "the manager takes no message here")
            store.setDraft("Ship the newsletter on Monday.", for: "manager")
            #expect(await store.send(to: "manager") == nil)
            try await Self.until { hub.messageTries == 1 && !store.sending }
            await store.refresh()
            try await Task.sleep(for: .milliseconds(400))
            #expect(hub.messageTries == 1 && store.resend == nil, "a chat message went again by itself")
            #expect(store.pending != nil && store.pending?.needID == nil && store.pending?.refusal == nil,
                    "the cut message left the Outbox")
        }
    }

    /// **A refused answer of a card that another hand answered leaves at the read that its send makes** (the owner,
    /// 22 November 2026: "cards on the phone are left with Sending... and never complete"; `MobileStore.readSnapshot`):
    /// the Mac answers card 7, the hub refuses the phone's answer to it, and the read at the end of that send no longer
    /// lists 7 as open, so the request leaves, and no "Refused" stays. The bug that this stops: that read came while
    /// the send still held `sending`, which a Discard waits for, and the later reads of an unchanged fleet answer 304,
    /// so the request stood in Settings as "Refused", with reads every 10 seconds, until the next write.
    @MainActor @Test("a refused answer of a card that another hand answered leaves at the read of its send",
                     .timeLimit(.minutes(1)))
    func aRefusedAnswerOfAClosedCardLeaves() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.answerElsewhere(7)
            hub.mode = .refuses
            store.press(needID: 7, choice: 0)
            try await Self.until { hub.tries.count == 1 && !store.sending }
            try #require(hub.tries == ["/ui/needs/7"] && !store.openNeeds.contains { $0.id == 7 })
            #expect(store.pending == nil, "the refused answer of a card that closed stays")
            #expect(try Outbox(file: Self.support.appendingPathComponent("pending.json")).load() == nil)
        }
    }

    /// **A Pause and a message under a card go after a refused answer** (the owner, 22 November 2026: "cards on the
    /// phone are left with Sending... and never complete"; the doors `MobileStore.pause(task:)` and
    /// `talk(needID:words:)`): the hub refuses card 8's answer, and card 8 stays open; a task's Pause then goes, and so
    /// does his message under card 7 after a second refusal; each refused request left the Outbox first. The bugs that
    /// this stops: a door that saves a request while a refused one is in the Outbox, which refuses a second request, so
    /// the phone says that sending is blocked and nothing goes; and a door that waits behind the refusal.
    @MainActor @Test("a Pause and a message under a card go after a refused answer", .timeLimit(.minutes(1)))
    func aPauseAndAMessageGoAfterARefusedAnswer() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.mode = .refuses
            store.press(needID: 8, choice: 1)
            try await Self.until { hub.tries.count == 1 && !store.sending }
            try #require(store.pending?.needID == 8 && store.pending?.refusal != nil)
            try #require(store.openNeeds.contains { $0.id == 8 })

            await store.pause(task: 41)
            #expect(hub.commands == ["/ui/tasks/41/control"], "the Pause did not go after the refused answer")
            #expect(store.pending == nil && store.storageError == nil)

            store.press(needID: 8, choice: 0)
            try await Self.until { hub.tries.count == 2 && !store.sending }
            try #require(store.pending?.needID == 8 && store.pending?.refusal != nil)
            await store.talk(needID: 7, words: "Is it the same customer as last month?")
            #expect(hub.commands == ["/ui/tasks/41/control", "/ui/needs/7/talk"],
                    "the message under the card did not go after the refused answer")
            #expect(store.pending == nil && store.storageError == nil)
        }
    }

    /// **Words that look like a key wait for his choice in the answer's box** (`NeedAnswerBox`, `MobileStore.holdSend`,
    /// `NeedKeyHold`; the owner, 22 November 2026: "Yes, the same in both", as the chat's Keep it): Send on an answer
    /// that holds a made-up key shows the line over the field, "That looks like a key. Never send a key in a message.",
    /// with Keep it, starts no wait with Undo, and the hub gets no request, also from the store's own Send; the words
    /// stay in the field. Any change of the words takes the line and Keep it away, also a change from outside the box,
    /// and the same words again show no line until a Send. A new generation empties the box, and the hold of the old
    /// one shows no line and its Keep it sends nothing. Keep it of other words sends nothing; Keep it sends those exact
    /// words, after their wait, once. A plain answer goes. The bugs that this stops: the box sent such words with no
    /// look, into the agent's conversation, where nothing masks a key before it is read; it then held back a normal
    /// link that looks like a key with no way past (a meeting link, a shared file's link); a Keep it that sent words
    /// that he no longer saw; and the old generation's words in the new item 7's box, which a plain Send sent there.
    @MainActor @Test("an answer that looks like a key waits for Keep it, which sends those exact words once",
                     .timeLimit(.minutes(1)))
    func anAnswerThatLooksLikeAKeyIsHeldBack() async throws {
        try await Self.withAnswerHub { store, hub in
            store.answerWait = .milliseconds(100)
            defer { store.setAnswerDraft("", for: 7); store.setAnswerDraft("", for: 8) }
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            let window = CardWindow(NeedCard(store: store, need: need, header: false))
            defer { window.close() }
            // a made-up key, from two parts, so no file holds a key's whole shape
            let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
            store.setAnswerDraft(key, for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("send-answer-7"))
            try await Task.sleep(for: .milliseconds(400))
            #expect(window.parts.keys.contains("answer-key-7"), "no line says that the words look like a key")
            #expect(window.parts.keys.contains("answer-keep-7"), "the line has no Keep it")
            #expect(store.heldAnswer(to: 7) == nil && store.waitingPresses.isEmpty && store.pending == nil)
            #expect(store.answerDraft(for: 7) == key)
            // the store's own Send holds them back too, and Keep it of other words sends nothing
            let hold = try #require(store.holdSend(needID: 7))
            #expect(hold.need == 7 && hold.box == .answer && hold.words == key && store.isCurrent(hold))
            let other = MobileStore.NeedKeyHold(hub: hold.hub, database: hold.database, need: 7, box: .answer,
                                                words: key + "!")
            #expect(store.holdSend(needID: 7, keeping: other) == hold)
            await store.send(needID: 7)
            try await Task.sleep(for: .milliseconds(400))
            #expect(store.heldAnswer(to: 7) == nil && store.pending == nil && hub.tries.isEmpty)

            // a change of the words, here a space at their end from outside the box, takes the line and Keep it away,
            // and the same words again show none until a Send
            store.setAnswerDraft(key + " ", for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("answer-key-7") && !window.parts.keys.contains("answer-keep-7"))
            store.setAnswerDraft(key, for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("answer-key-7"), "the line came back with no Send")

            // a hold of another generation: no line, and its Keep it sends nothing
            #expect(window.press("send-answer-7"))
            try await Task.sleep(for: .milliseconds(300))
            let before = try #require(store.holdSend(needID: 7))
            hub.database = "gen-answers-2"
            await store.refresh()
            try #require(store.snapshot?.db == "gen-answers-2")
            try await Task.sleep(for: .milliseconds(300))
            #expect(!store.isCurrent(before) && !window.parts.keys.contains("answer-keep-7"))
            // the old generation's words stand in no box of the new one: its item 7 is another item
            #expect(store.answerDraft(for: 7).isEmpty, "the old generation's words stand in the new item 7's box")
            store.setAnswerDraft(key, for: 7)
            #expect(store.holdSend(needID: 7, keeping: before) != nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(hub.tries.isEmpty && store.heldAnswer(to: 7) == nil, "the Keep it of another generation sent")

            // Send again, then Keep it: those exact words wait their wait with Undo, and go once
            #expect(window.press("send-answer-7"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("answer-keep-7"), "the line has no Keep it to press")
            try await Self.until { hub.taken == [7] && store.pending == nil && !store.sending }
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.tries == ["/ui/needs/7"] && hub.words == [key], "Keep it did not send those words once")

            // a plain answer goes
            store.setAnswerDraft("Send it, but on Tuesday", for: 8)
            #expect(store.holdSend(needID: 8) == nil)
            try await Self.until { hub.taken == [7, 8] && store.pending == nil && !store.sending }
            #expect(hub.words == [key, "Send it, but on Tuesday"])
        }
    }

    /// **An answer's draft keeps no words that look like a key on the phone's disk, and leaves when its request
    /// closes** (`MobileStore.setAnswerDraft`, `keepAnswerDrafts`, `readSnapshot`), as the words of Needs
    /// clarification, which stay in memory only: a key pasted into an answer by mistake stayed in the app's settings
    /// file, also after its request was answered elsewhere. Drafts that an earlier build kept leave the disk at the
    /// store's start, and stay in memory. A plain draft is kept until its request closes, and while the same fleet's
    /// generation answers at another address; a new generation takes it away.
    @MainActor @Test("an answer's draft keeps no key-like words on the disk, and leaves when its request closes",
                     .timeLimit(.minutes(1)))
    func anAnswersDraftKeepsNoKeyOnTheDisk() async throws {
        func onDisk() -> [String: String] {
            UserDefaults.standard.dictionary(forKey: "answerDrafts") as? [String: String] ?? [:]
        }
        let saved = (UserDefaults.standard.object(forKey: "answerDrafts"),
                     UserDefaults.standard.object(forKey: "answerDraftsPlace"))
        defer {
            if let drafts = saved.0 { UserDefaults.standard.set(drafts, forKey: "answerDrafts") }
            else { UserDefaults.standard.removeObject(forKey: "answerDrafts") }
            if let place = saved.1 { UserDefaults.standard.set(place, forKey: "answerDraftsPlace") }
            else { UserDefaults.standard.removeObject(forKey: "answerDraftsPlace") }
        }
        // drafts as an earlier build kept them, a key-like one among them, with no record of their hub
        let key = "Use this one: " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
        UserDefaults.standard.set(["7": key, "8": "Send it on Tuesday"], forKey: "answerDrafts")
        UserDefaults.standard.removeObject(forKey: "answerDraftsPlace")
        try await Self.withAnswerHub { store, hub in
            defer { store.setAnswerDraft("", for: 7); store.setAnswerDraft("", for: 8) }
            #expect(onDisk()["7"] == nil, "the key-like words of an earlier build stay on the phone's disk")
            #expect(store.answerDraft(for: 7) == key && store.answerDraft(for: 8) == "Send it on Tuesday")
            #expect(onDisk()["8"] == "Send it on Tuesday")
            // a key-like draft written now stays in memory only
            store.setAnswerDraft(key + " now", for: 7)
            #expect(store.answerDraft(for: 7) == key + " now" && onDisk()["7"] == nil)
            // another hand answers request 8: the next read takes its draft away, from memory and from the disk
            hub.answerElsewhere(8)
            await store.refresh()
            try #require(!store.openNeeds.contains { $0.id == 8 })
            #expect(store.answerDraft(for: 8).isEmpty && onDisk()["8"] == nil, "the draft of a closed request stays")
            #expect(store.answerDraft(for: 7) == key + " now")

            // the same fleet at another address keeps its drafts; a new generation there takes them away
            store.setAnswerDraft("Refund it in full", for: 7)
            let moved = AnswerHub()
            defer { moved.stop() }
            store.addressText = try await moved.start()
            await store.connect()
            try #require(store.readError == nil && store.snapshot?.db == "gen-answers-1")
            #expect(store.answerDraft(for: 7) == "Refund it in full" && onDisk()["7"] == "Refund it in full",
                    "the same generation at another address lost its drafts")
            moved.database = "gen-answers-2"
            await store.refresh()
            try #require(store.snapshot?.db == "gen-answers-2")
            #expect(store.answerDraft(for: 7).isEmpty && onDisk()["7"] == nil, "a new generation kept the old drafts")
        }
    }

    /// **His message under a card that looks like a key waits for Keep it; his words about a key request never go**
    /// (the field of Needs clarification, `NeedClarify`; `MobileStore.talk(needID:words:keeping:)` and
    /// `clarify(needID:words:)`; the owner, 22 November 2026: "Yes, the same in both", and the area's call "as on the
    /// Mac" for a key request): on an ordinary card Send shows the line over the field with Keep it, and nothing is
    /// saved; any change of the words takes them away, a space at their end too, and the same words again show none
    /// until a Send; Keep it sends those exact words once, on the card's own route. On a key request (card 9) the line
    /// stands with no Keep it, and such words never go, as from the Mac's form; plain words go on its own route. The
    /// bugs that this stops: a key in his words that goes into the agent's conversation, a normal link that could never
    /// go, and a line that stayed after an edit of the spaces at its end.
    @MainActor @Test("his message under a card that looks like a key waits for Keep it, and never about a key request",
                     .timeLimit(.minutes(1)))
    func aMessageThatLooksLikeAKeyWaitsForKeepIt() async throws {
        try await Self.withAnswerHub { store, hub in
            defer { store.setClarifyDraft("", for: 7); store.setClarifyDraft("", for: 9) }
            let key = "Is this the one? " + "sk-" + "ant-api03-" + String(repeating: "EXAMPLE", count: 4)
            let need = try #require(store.openNeeds.first { $0.id == 7 })
            let window = CardWindow(NeedCard(store: store, need: need, header: false))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("clarify-link-7"))
            store.setClarifyDraft(key, for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("send-clarify-7"))
            try await Task.sleep(for: .milliseconds(400))
            #expect(window.parts.keys.contains("clarify-key-7") && window.parts.keys.contains("clarify-keep-7"),
                    "no line with Keep it over the field")
            #expect(hub.commands.isEmpty && store.pending == nil)

            // a change of only a space at the words' end takes the line and Keep it away, and the same words again
            // show none until a Send
            store.setClarifyDraft(key + " ", for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("clarify-key-7") && !window.parts.keys.contains("clarify-keep-7"))
            store.setClarifyDraft(key, for: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!window.parts.keys.contains("clarify-key-7"), "the line came back with no Send")

            // Send again, then Keep it: those exact words go once, as his message under the card
            #expect(window.press("send-clarify-7"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("clarify-keep-7"), "the line has no Keep it to press")
            try await Self.until { !hub.commands.isEmpty && store.pending == nil && !store.sending }
            try await Task.sleep(for: .milliseconds(600))
            #expect(hub.commands == ["/ui/needs/7/talk"] && hub.words == [key], "Keep it did not send those words once")

            // a key request: the line with no Keep it, and such words never go
            let keyNeed = try #require(store.openNeeds.first { $0.id == 9 })
            let keyCard = CardWindow(NeedCard(store: store, need: keyNeed, header: false))
            defer { keyCard.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(keyCard.press("clarify-link-9"))
            store.setClarifyDraft(key, for: 9)
            try await Task.sleep(for: .milliseconds(300))
            #expect(keyCard.press("send-clarify-9"))
            try await Task.sleep(for: .milliseconds(400))
            #expect(keyCard.parts.keys.contains("clarify-key-9"), "no line over the key request's field")
            #expect(!keyCard.parts.keys.contains("clarify-keep-9"), "a key request's field offers Keep it")
            #expect(await store.clarify(needID: 9, words: key) != nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(hub.tries.isEmpty && store.pending == nil, "words about a key request went")
            // plain words about it go, on its own route
            #expect(await store.clarify(needID: 9, words: "Which account is it for?") == nil)
            try await Self.until { hub.tries == ["/ui/needs/9/secret"] && store.pending == nil && !store.sending }
            #expect(hub.words == [key, "Which account is it for?"])
        }
    }
}

extension SampleFleetTests {
    /// A request's card of the manager's, from the hub's fields.
    private static func card(_ fields: [String: Any]) throws -> OwnerNeed {
        let base: [String: Any] = [
            "id": 41, "by": "manager", "title": "Add prepaid credits for the search agents' reads?", "raised": 20,
            "todo": "", "options": ["Yes, I'll add credits", "No, leave it out for now"],
        ]
        return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(
            withJSONObject: base.merging(fields) { _, new in new }))
    }

    /// The height of `words` as a block of the subheadline type in `width`, at the text size `size`.
    @MainActor private static func height(_ words: String, font: Font = .subheadline, width: CGFloat,
                                          size: DynamicTypeSize = .large) -> CGFloat {
        UIHostingController(rootView: Text(verbatim: words).font(font).environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// **A long reason stands in three lines with "…" on the card's front, and Details opens it whole** (`NeedReason`,
    /// `NeedDetailsLink`; the owner, 22 November 2026: "cards on the phone have TOO much information at once", and his
    /// "Yes, as drawn" to pictures 2 and 3 of F9): a reason of 240 characters shows three of its lines and the link
    /// Details, collapsed; a press opens it, and the reason stands whole; a second press folds it. A short reason with
    /// no task and no long part stands whole, with no link. The bugs that this stops: a reason that is cut and that
    /// nothing opens, so its end is lost on the phone; and a link that opens nothing.
    @MainActor @Test("a long reason is cut to three lines, and Details opens it whole", .timeLimit(.minutes(1)))
    func aLongReasonIsCutAndDetailsOpensIt() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let why = "The search key works, but the provider answers \"credits depleted\", so the agents' checks of "
                + "mentions, buyer words and rivals read nothing at all. The checks read only new posts, "
                + "and none since. The agents wait for new credits before they read again, and the week's "
                + "report has no numbers until then."
            try #require(why.count > 250)
            let window = CardWindow(NeedCard(store: store, need: try Self.card(["why": why]), header: false))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            let rest = try #require(window.frame(of: "need-reason-41"), "the card shows no reason")
            let line = Self.height("A", width: rest.width), whole = Self.height(why, width: rest.width)
            try #require(whole > line * 4.5, "the reason fits four lines here: the check proves nothing")
            #expect(rest.height < line * 3.5, "the reason at rest is \(rest.height) points: not three lines")
            #expect(window.parts["need-details-41"]?.accessibilityValue == "Collapsed", "no Details link, collapsed")

            #expect(window.press("need-details-41"))
            try await Task.sleep(for: .milliseconds(500))
            let open = try #require(window.frame(of: "need-reason-41"))
            #expect(open.height >= whole - 1, "the open reason is \(open.height) points of \(whole)")
            #expect(window.parts["need-details-41"]?.accessibilityValue == "Expanded")
            #expect(window.press("need-details-41"))
            try await Task.sleep(for: .milliseconds(500))
            #expect((window.frame(of: "need-reason-41")?.height ?? 0) < line * 3.5, "a second press did not fold it")

            // a short reason with nothing behind it: whole, and no link
            let short = CardWindow(NeedCard(store: store, need: try Self.card(["id": 42, "why": "The key works."]),
                                            header: false))
            defer { short.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(short.parts["need-reason-42"] != nil && short.parts["need-details-42"] == nil)
        }
    }

    /// **Details shows the task and the long part, and nothing of them stands on the front at rest** (the owner's "Yes,
    /// as drawn" to picture 3 of F9): the card at rest has the reason, the link, the options and Your answer, and no
    /// word of the task or the long part; a press of Details shows both under the link, and the options and the answer
    /// keep their place. A key request's card never shows the hub's own sentence there, only its steps. The bugs that
    /// this stops: the phone showed the long part nowhere and the task of a card with options nowhere, so a card whose
    /// steps exist could not be done from the phone; and the key card that said the Mac twice.
    @MainActor @Test("Details shows the task and the long part, and the front shows neither", .timeLimit(.minutes(1)))
    func detailsShowsTheTaskAndTheLongPart() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let task = "Decide whether to add prepaid credits on the provider's billing page."
            let long = "Marketing's estimate, not yet measured: about 100 to 300 posts a day over its seven searches."
            let need = try Self.card(["why": "The search key works, but its credits are gone.", "todo": task,
                                      "details": long])
            let window = CardWindow(NeedCard(store: store, need: need, header: false))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            let atRest = window.labels
            #expect(!atRest.contains { $0.contains("billing page") || $0.contains("Marketing's estimate") },
                    "the task or the long part stands on the front at rest")
            #expect(window.parts.keys.contains("need-option-41-0") && window.parts.keys.contains("answer-41"))
            #expect(window.press("need-details-41"), "the card has no Details link")
            try await Task.sleep(for: .milliseconds(500))
            let open = window.labels
            #expect(open.contains { $0.contains("billing page") }, "Details does not show the task")
            #expect(open.contains { $0.contains("Marketing's estimate") }, "Details does not show the long part")
            #expect(window.parts.keys.contains("need-option-41-1") && window.parts.keys.contains("answer-41"))

            // a key request: its steps behind Details, and never the hub's own sentence
            let key = try Self.card(["id": 43, "kind": "secret", "options": [],
                                     "title": "Enter the API key SHOP_MAIL_KEY for mail.example.com",
                                     "why": "The shop's mail key ends today.",
                                     "todo": "Open this request in Founderizer on your Mac and type it into its form.",
                                     "details": "1. Open the mail service's key page.\n2. Make a key that sends mail."])
            let keyCard = CardWindow(NeedCard(store: store, need: key, header: false))
            defer { keyCard.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(keyCard.press("need-details-43"), "the key card has no Details link")
            try await Task.sleep(for: .milliseconds(500))
            let keyWords = keyCard.labels
            #expect(keyWords.contains { $0.contains("Make a key that sends mail") }, "Details does not show the steps")
            #expect(!keyWords.contains { $0.contains("Open this request in Founderizer") })
        }
    }

    /// **Nothing of the card is cut at the largest text size** (picture 13 of F9: the answer's box read "Your ans…"):
    /// at the largest accessibility size, in the width of a card on Needs you of a phone 375 points wide (343), the
    /// box's empty field takes the room of its prompt whole, as much as the same words typed take, and each option's
    /// whole label stands in its row with room over and under it. The bug that this stops: the field's own prompt
    /// stands on one line and is cut where it does not fit.
    @MainActor @Test("nothing of the card is cut at the largest text size, the answer's prompt neither",
                     .timeLimit(.minutes(1)))
    func nothingOfTheCardIsCutAtTheLargestSize() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            defer { store.setAnswerDraft("", for: 41) }
            let need = try Self.card(["why": "The search key works, but its credits are gone."])
            /// Where the field and Send stand at the largest size, with these words in the box.
            @MainActor func box(_ words: String) async throws -> (field: CGRect, send: CGRect, rows: [CGRect]) {
                store.setAnswerDraft(words, for: 41)
                let window = CardWindow(NeedCard(store: store, need: need, header: false)
                    .environment(\.dynamicTypeSize, .accessibility5).frame(width: 343))
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(500))
                return (try #require(window.frame(of: "answer-41")), try #require(window.frame(of: "send-answer-41")),
                        try need.choices.indices.map { try #require(window.frame(of: "need-option-41-\($0)")) })
            }
            let typed = try await box("Your answer")
            let empty = try await box("")
            let line = Self.height("A", font: .body, width: typed.field.width, size: .accessibility5)
            try #require(typed.field.height > line * 1.5, "the words fit one line here: the check proves nothing")
            #expect(abs(empty.send.maxY - typed.send.maxY) < 1,
                    "the empty box is \(typed.send.maxY - empty.send.maxY) points lower than its prompt needs")
            for (label, row) in zip(need.choices, empty.rows) {
                let words = Self.height(label, font: .body, width: row.width - 28, size: .accessibility5)
                #expect(row.height - words >= 20, "\(label): a row of \(row.height) points for \(words) of words")
            }
        }
    }

    /// **A key's long name in a card's title breaks after an underscore, with no hyphen** (`NeedCard.drawnTitle`; pictures
    /// 1 and 7 of F9 broke a name as "DOOR_EXAMPLE_PROVI-" over "DER_KEY" does): the title as the card draws it breaks into
    /// lines only after a space or after an underscore of the name, in the title's own width and type, and VoiceOver reads
    /// the title as the hub wrote it. The bug that this stops: a name with no place to break, which the system cut inside
    /// with a hyphen that is not part of it, so he read or copied a wrong name.
    @MainActor @Test("a key's long name in a card's title breaks after an underscore, with no hyphen",
                     .timeLimit(.minutes(1)))
    func aKeysNameInATitleBreaksAtItsUnderscores() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let title = "Enter the API key SHOP_MAIL_PROVIDER_ACCOUNT_SENDING_KEY_FOR_THE_WEST for mail.example.com"
            let need = try Self.card(["id": 44, "title": title, "why": "The shop's mail key ends today."])
            let window = CardWindow(NeedCard(store: store, need: need, header: false))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            let frame = try #require(window.frame(of: "need-title-44"), "the card shows no title")
            #expect(window.parts["need-title-44"]?.accessibilityLabel == title, "VoiceOver reads other characters")

            // the drawn title's lines, in the title's width and type: each breaks after a space or an underscore
            let drawn = NeedCard.drawnTitle(title)
            let units = Array(drawn.utf16)
            let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(
                string: drawn, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]))
            var start = 0
            var breaks: [Int] = []
            while start < units.count {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(frame.width))
                guard count > 0 else { break }
                start += count
                if start < units.count { breaks.append(start) }
            }
            try #require(breaks.count >= 2, "the name fits one line here: the check proves nothing")
            for index in breaks {
                let line = String(decoding: units[max(0, index - 8)..<index], as: UTF16.self)
                #expect(units[index - 1] == 0x20 || units[index - 1] == 0x200B, "a line ends inside a word: \(line)")
            }
            // nothing but those breaks is added: the drawn title is the title with a zero-width space after the
            // name's underscores
            #expect(drawn.replacingOccurrences(of: "\u{200B}", with: "") == title)
        }
    }

    /// **The door card's script stands behind the link Script** (the owner's "Yes, as drawn" to picture 11 of F9,
    /// "Behind a Script link, as on the Mac"): on Needs you, with no press, the card shows its reason, the link Script,
    /// collapsed, and Run it once, and no line of the script (his picture 11a: the card stands open); a press of
    /// Script shows the script whole. The bugs that this stops: a script that he cannot read before he signs Run it
    /// once, because nothing opens it, and the door card at rest with Run it once and no Script (the readers of 22
    /// November 2026).
    @MainActor @Test("the door card's script stands behind Script, which shows it whole", .timeLimit(.minutes(1)))
    func aDoorCardsScriptStandsBehindScript() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let script = "systemctl reload nginx\ndate -u\n"
            let call = DoorCall.hash(target: "web-1", action: DoorCall.run, arguments: [], content: Data(script.utf8))
            let door = try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
                "id": 45, "by": "manager", "title": DoorCall.title(host: "web-1"), "raised": 20, "todo": "",
                "why": "The certificate of web-1 ends on Friday.", "options": DoorCall.answers(host: "web-1"),
                "door_call": call, "door_fleet": "fleet-1", "door_host": "web-1", "door_script": script,
                "details": DoorCall.details(script: script),
            ] as [String: Any]))
            let window = CardWindow(NeedCard(store: store, need: door, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(!window.labels.contains { $0.contains("systemctl reload nginx") }, "the script stands at rest")
            #expect(window.parts["need-details-45"]?.accessibilityLabel?.contains("Script") == true)
            #expect(window.parts["need-details-45"]?.accessibilityValue == "Collapsed")
            #expect(window.parts.keys.contains("need-option-45-0"), "no Run it once")
            #expect(window.press("need-details-45"), "the card has no link Script")
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.labels.contains { $0.contains("systemctl reload nginx") && $0.contains("date -u") },
                    "Script does not show the script whole")
        }
    }

    /// **An answered card in a chat has the open card's form** (the owner's "Yes, as drawn" to picture 12 of F9): its
    /// whole request shows the reason and the task with no label "Why" or "What it wants", his answer under "Your
    /// answer", and "Answered" at the end of its title line. The bug that this stops: the answered card kept the labels
    /// that the open card no longer has.
    @MainActor @Test("an answered card in a chat shows its words with no label, as the open card",
                     .timeLimit(.minutes(1)))
    func anAnsweredCardHasTheOpenCardsForm() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let answered = try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
                "id": 46, "by": "manager", "title": "Which server?", "raised": 22, "todo": "Pick one of the two.",
                "why": "The shop needs one server for its sale.", "answer": "Use the second one.", "answered": 30,
            ] as [String: Any]))
            let window = CardWindow(NeedCard(store: store, need: answered))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.press("need-folded-46"), "the answered card does not open")
            try await Task.sleep(for: .milliseconds(400))
            let words = window.labels
            #expect(words.contains { $0.contains("The shop needs one server") })
            #expect(words.contains { $0.contains("Pick one") })
            #expect(!words.contains("Why") && !words.contains("What it wants"), "the answered card keeps its labels")
            #expect(window.parts["need-fold-46"]?.accessibilityLabel?.contains("Answered") == true)
        }
    }

    /// **A card on Needs you stands alone at rest, with one line of its reason and its options, and a press opens it**
    /// (the owner's "Form A: each card alone" of 22 November 2026: "It has to be simpler"; `NeedCard.atRest`): at rest
    /// the card shows its question, one line of a long reason and its options, and no Your answer and no Details; a
    /// press of the card opens it as the single card, with the reason in more lines, Details and Your answer. The bugs
    /// that this stops: a card at rest that shows more than one line of its reason, and a press that does not open it.
    @MainActor @Test("a card at rest on Needs you shows one line of its reason and its options, and a press opens it",
                     .timeLimit(.minutes(1)))
    func aCardAtRestShowsOneLineAndAPressOpensIt() async throws {
        try await Self.withoutHub {
            let store = MobileStore()
            let why = "The search key works, but the provider answers that its credits are gone, so the agents' checks "
                + "of mentions and buyer words read nothing."
            let need = try Self.card(["id": 47, "why": why, "todo": "Decide on the provider's billing page.",
                                      "details": "Marketing's estimate, not yet measured."])
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            let rest = try #require(window.frame(of: "need-reason-47"), "the card at rest shows no reason")
            let line = Self.height("A", width: rest.width)
            try #require(Self.height(why, width: rest.width) > line * 1.5, "the reason fits one line here")
            #expect(rest.height < line * 1.5, "the card at rest shows \(rest.height) points of its reason")
            #expect(window.parts.keys.contains("need-option-47-0") && window.parts.keys.contains("need-option-47-1"),
                    "the card at rest has no options to press")
            #expect(window.parts["answer-47"] == nil && window.parts["need-details-47"] == nil,
                    "the card at rest shows more than its question, its reason and its options")

            #expect(window.press("need-rest-47"), "the card at rest has no press that opens it")
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.parts.keys.contains("answer-47") && window.parts.keys.contains("need-details-47"),
                    "a press does not open the card")
            #expect((window.frame(of: "need-reason-47")?.height ?? 0) > line * 1.5,
                    "the open card shows one line of its reason")

            // a card that holds his words stands open with no press; one with nothing to press has its box at rest
            store.setAnswerDraft("Only the search agent, please", for: 48)
            defer { store.setAnswerDraft("", for: 48) }
            let drafted = CardWindow(NeedCard(store: store, need: try Self.card(["id": 48, "why": why]), header: true))
            defer { drafted.close() }
            let bare = CardWindow(NeedCard(store: store, need: try Self.card(["id": 49, "why": why, "options": []]),
                                           header: true))
            defer { bare.close() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(drafted.parts.keys.contains("answer-48"), "a card with his words in its box stands at rest")
            // once open, it stays open when his words go from the box
            store.setAnswerDraft("", for: 48)
            try await Task.sleep(for: .milliseconds(400))
            #expect(drafted.parts.keys.contains("answer-48") && drafted.parts.keys.contains("need-title-48")
                    && drafted.parts["need-rest-48"] == nil, "the card went back to rest when its box emptied")
            #expect(bare.parts.keys.contains("need-rest-49") && bare.parts.keys.contains("answer-49")
                    && bare.parts["need-details-49"] == nil,
                    "a card with nothing to press has no box at rest, or stands open")
            #expect(bare.press("need-rest-49"), "the card with its box at rest does not open")
            try await Task.sleep(for: .milliseconds(500))
            #expect(bare.parts.keys.contains("need-title-49") && bare.parts["need-rest-49"] == nil,
                    "a press does not open the card with its box at rest")
        }
    }

    /// **A press on the agent's recommended words at rest folds the card from its rest, and Undo puts it back at rest**
    /// (the second reading of the fix round, 22 November 2026; `NeedCard.standsOpen`): the press puts the words in the
    /// answer's box while they wait 5 seconds with Undo, which is no reason to open the card. The bug that this stops:
    /// the words in the box opened the card in the frame of the press, so its fold began from the open form while the
    /// card on screen was at rest, and after Undo it stood open for good.
    @MainActor @Test("a press on the recommended words at rest, then Undo, leaves the card at rest",
                     .timeLimit(.minutes(1)))
    func recommendedWordsAndUndoLeaveTheCardAtRest() async throws {
        try await Self.withAnswerHub { store, hub in
            hub.recommendsWords = true
            await store.refresh()
            let need = try #require(store.openNeeds.first { $0.id == 8 })
            try #require(NeedOptions.recommendedWords(need, store: store) != nil, "card 8 has no recommended words")
            store.answerWait = .seconds(3)
            defer { store.setAnswerDraft("", for: 8) }
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            try #require(window.parts.keys.contains("need-rest-8"), "card 8 does not stand at rest")
            #expect(window.press("need-recommended-8"))
            try await Task.sleep(for: .milliseconds(400))
            #expect(window.press("need-undo-8"), "the folded card has no Undo")
            try await Task.sleep(for: .milliseconds(700))
            #expect(window.parts.keys.contains("need-rest-8") && window.parts["answer-8"] == nil,
                    "Undo left the card open")
            #expect(hub.tries.isEmpty && store.answerDraft(for: 8).isEmpty)
        }
    }

    /// **The options that he ticked stay when the card opens** (`NeedCard.ticked`; the readers of 22 November 2026):
    /// on Needs you he ticks two options of a card whose options combine, at rest, and opens the card; the same two
    /// stand ticked and Send counts them, on the card of pictures (9) and on the card of plain rows (10). The bug that
    /// this stops: the card at rest and the open card each drew rows of their own, so a press that opened the card took
    /// his ticks away.
    @MainActor @Test("the options that he ticked at rest stay when the card opens", .timeLimit(.minutes(1)),
                     arguments: [9, 10])
    func ticksStayWhenTheCardOpens(card: Int) async throws {
        try await Self.withPictureHub { store, _ in
            let need = try #require(store.openNeeds.first { $0.id == card })
            let window = CardWindow(NeedCard(store: store, need: need, header: true))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            try #require(!window.parts.keys.contains("answer-\(card)"), "the card does not stand at rest")
            #expect(window.press("need-tick-\(card)-2") && window.press("need-tick-\(card)-0"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.press("need-rest-\(card)"), "the card at rest has no press that opens it")
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.parts.keys.contains("answer-\(card)"), "the press did not open the card")
            #expect(window.has("need-tick-\(card)-0", .selected) && window.has("need-tick-\(card)-2", .selected),
                    "the ticks went when the card opened")
            #expect(!window.has("need-tick-\(card)-1", .selected))
            #expect(window.parts["need-send-ticked-\(card)"]?.accessibilityLabel?.contains("2") == true,
                    "Send does not count the two ticks")
        }
    }
}

/// **A hub with two cards whose first option starts a step on the Mac**: card 7 makes a GitHub App (`github_app`),
/// card 8 opens the Add device picture (`add_device`), each with "Not now" as its second option. It takes an answer
/// with the hub's receipt, as the hub does from a phone, and keeps the route and the option of each one, in order.
private final class MacStepHub: LoopbackHub, @unchecked Sendable {
    private var routes: [String] = []
    private var options: [Int] = []

    init() { super.init(label: "founderizer.check.mac-step-hub") }

    /// The route of each answer that came, in order.
    var answers: [String] { lock.withLock { routes } }
    /// The option of each answer that came, in order.
    var choices: [Int] { lock.withLock { options } }

    override func answer(_ request: Request, on connection: NWConnection) {
        let route = "\(request.method) \(request.path)"
        note(route)
        switch route {
        case "GET /ui/mobile":
            send(Self.reply(200, Self.fleet), on: connection)
        case "POST /ui/needs/7", "POST /ui/needs/8":
            let fields = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            lock.withLock {
                routes.append(request.path)
                options.append(fields["choice"] as? Int ?? -1)
            }
            let receipt: [String: Any] = ["ok": true, "request_id": fields["request_id"] as? String ?? "",
                                          "event_id": 101, "replayed": false, "created": 1_800_000_100,
                                          "client": request.headers["x-fleet-client"] ?? ""]
            let body = (try? JSONSerialization.data(withJSONObject: receipt))
                .map { String(decoding: $0, as: UTF8.self) }
            send(Self.reply(200, body ?? "{}"), on: connection)
        default:
            send(Self.reply(404, #"{"error": "not found"}"#), on: connection)
        }
    }

    private static let fleet: String = {
        func card(_ id: Int, _ title: String, _ first: String, _ step: [String: Any]) -> [String: Any] {
            ["id": id, "by": "manager", "title": title, "why": "The door holds no way in yet.", "todo": "",
             "raised": 1_799_999_000 + id, "answer": NSNull(), "answered": NSNull(), "options": [first, "Not now"]]
                .merging(step) { _, new in new }
        }
        let fleet: [String: Any] = [
            "schema_version": 1, "db": "gen-mac-step", "time": 1_800_000_000,
            "ui_features": ["mobile", "need_options"], "agents": [],
            "needs": [card(7, "Make the shop's own GitHub App in acme", "Make the App", ["github_app": "acme"]),
                      card(8, "Scan the Add device picture again", "Scan it again", ["add_device": 1])],
            "tasks": [], "recent": [], "holds": [], "outcomes": [],
        ]
        return (try? JSONSerialization.data(withJSONObject: fleet)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }()
}

extension SampleFleetTests {
    /// **A GitHub App's and an Add device card's first option is drawn, grey, and takes no press on the phone**
    /// (`OwnerNeed.firstOptionStartsOnTheMac`; rows 19 and 21 of the owner's list of 22 November 2026, and his answer:
    /// "we need to enable it so everything can be done on the phone!", with no new line for the time between): a press
    /// of it, by the card, by each of the store's routes (a wait with Undo, a press, a send) or by a ping's button
    /// (`NeedPress.answer`), holds and sends nothing, and the card stays with its other options and Your answer, which
    /// still go: "Not now" goes as its own option, from the card and from a ping.
    /// The bugs that this stops: the press answered the card, closed it, and started nothing, because only the Mac's
    /// press makes the App or opens the picture; and a route of the store that the guard of one route did not cover.
    @MainActor @Test("a first option that only the Mac starts is grey on the phone and sends nothing",
                     .timeLimit(.minutes(1)))
    func aFirstOptionThatOnlyTheMacStartsSendsNothing() async throws {
        try await Self.withoutHub {
            try await Self.keepingReadings {
                let hub = MacStepHub()
                defer { hub.stop() }
                let address = try await hub.start()
                let holder = DeviceKey(account: "device-key-mac-step-check")
                try holder.remove()
                defer { try? holder.remove() }
                let store = MobileStore(deviceKey: holder)
                try #require(store.pending == nil, "the simulator holds a request of its own")
                defer {
                    if let left = store.pending {
                        let outbox = Outbox(file: Self.support.appendingPathComponent("pending.json"))
                        try? outbox.clear(matching: left.requestID)
                    }
                }
                store.addressText = address
                await store.connect()
                try #require(store.canWrite && store.openNeeds.map(\.id).sorted() == [7, 8])
                store.answerWait = .milliseconds(100)

                for id in [7, 8] {
                    let need = try #require(store.openNeeds.first { $0.id == id })
                    let window = CardWindow(NeedCard(store: store, need: need, header: true))
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(window.parts["need-option-\(id)-0"] != nil, "card \(id): its first option is not drawn")
                    #expect(window.has("need-option-\(id)-0", .notEnabled),
                            "card \(id): its first option takes a press")
                    _ = window.press("need-option-\(id)-0")
                    store.hold(needID: id, choice: 0)
                    store.press(needID: id, choice: 0)
                    await store.send(needID: id, choice: 0)
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(store.heldAnswer(to: id) == nil && store.waitingPresses.isEmpty && hub.answers.isEmpty,
                            "card \(id): a press of its first option held or sent an answer")
                    #expect(store.pending == nil && store.openNeeds.contains { $0.id == id })
                    #expect(window.parts["need-option-\(id)-1"] != nil, "card \(id): its other option is not drawn")
                    // the open card has its answer's box too
                    #expect(window.press("need-rest-\(id)"), "card \(id): the card at rest does not open")
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(window.parts["answer-\(id)"] != nil, "card \(id): the open card has no Your answer")
                }

                // a ping's button: the first option is not sent, and "Not now" is, as itself
                let options = ["Scan it again", "Not now"]
                await NeedPress.answer(need: 8, choice: 0, options: options, keys: holder)
                #expect(hub.answers.isEmpty, "a ping's press of the first option sent it")
                await NeedPress.answer(need: 8, choice: 1, options: options, keys: holder)
                #expect(hub.answers == ["/ui/needs/8"] && hub.choices == [1], "a ping's Not now went as \(hub.choices)")
                // the line that the refused press posted ("Open Founderizer to answer.") leaves the simulator
                let center = UNUserNotificationCenter.current()
                let posted = await center.deliveredNotifications().map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: posted.filter { $0.hasPrefix("answer-8-") })
                let queued = await center.pendingNotificationRequests().map(\.identifier)
                center.removePendingNotificationRequests(withIdentifiers: queued.filter { $0.hasPrefix("answer-8-") })

                // its other option still goes from the card, as itself
                store.hold(needID: 7, choice: 1)
                try await Self.until { hub.answers.count == 2 && store.pending == nil && !store.sending }
                #expect(hub.answers == ["/ui/needs/8", "/ui/needs/7"] && hub.choices == [1, 1],
                        "Not now went as \(hub.choices)")
            }
        }
    }
}
