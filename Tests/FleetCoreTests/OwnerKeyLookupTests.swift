import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import FleetCore

/// **A read of the owner key that fails now never leads to a new owner key** (two Opus readers of the Windows owner
/// key, 24 November 2026), **and a key that no chip of this Mac opens leads to the path of a new Mac** (the
/// supervisor's item of 24 November 2026). The bugs that this catches: one passing error of the keychain (a locked
/// keychain, a refusal) or of the chip made the key nil, and the central vault's install then made a new owner key over
/// the old one, a new identity for the hub with no word to the owner, whose pins the Linux brokers refuse; an enclave
/// that refused a new key once gave a software key on a Mac that has an enclave; and a Mac that Migration Assistant made
/// from another Mac took the old chip's wrapped key for its own, so the vault's plan showed no Set up and each
/// signature failed.
struct OwnerKeyLookupTests {
    /// A key whose signature fails as the chip's does: the stand-in for a wrapped key that CryptoKit opened.
    private struct Refusing: OwnerKey {
        let error: Error
        var publicKey: String { "" }
        func sign(_ statement: String) throws -> String { throw error }
    }

    fileprivate static func tokenKit(_ code: Int) -> NSError { NSError(domain: "CryptoTokenKit", code: code) }

    /// Data that is no DER and no software key, new at each call: the shared record of this run is keyed by the data.
    private static func wrappedForm() -> Data {
        Data([0xFF] + (0..<283).map { _ in UInt8.random(in: 0...255) })
    }

    private static func soft(_ data: Data) -> OwnerKeychain.Opened {
        OwnerKeychain.open(data, chip: false, enclave: false, wrapped: { _ in throw tokenKit(-3) }, control: works)
    }

    /// The control of a chip that signs now, and of one that does not (a locked Mac, a token daemon that restarts).
    private static func works() throws {}
    private static func fails() throws { throw tokenKit(-3) }

    private static func failed(_ status: OSStatus) -> Result<Data, FleetKeychainItem.Failure> {
        .failure(FleetKeychainItem.Failure(label: "owner key", status: status))
    }

    @Test func onlyAnItemThatIsNotThereIsNone() {
        guard case .none = OwnerKeychain.lookup(Self.failed(errSecItemNotFound), open: Self.soft) else {
            Issue.record("an item that is not there is none")
            return
        }
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecDecode] {
            guard case .notNow(let failure) = OwnerKeychain.lookup(Self.failed(status), open: Self.soft),
                  failure.status == status else {
                Issue.record("the keychain's status \(status) is a read that failed now, never none")
                return
            }
        }
        let raw = P256.Signing.PrivateKey().rawRepresentation
        guard case .key = OwnerKeychain.lookup(.success(raw), open: Self.soft) else {
            Issue.record("a key that opens is the key")
            return
        }
    }

    /// **The chip's proof**: a wrapped form that CryptoKit opens is the key only once a signature with it worked. Bugs:
    /// another Mac's wrapped key is taken for this Mac's (it opens, and only its first signature fails), or a passing
    /// refusal of the chip (its daemon does not answer) is taken for another Mac's key, which leads to a new identity.
    @Test func anotherMacsKeyIsOtherMacAndAPassingRefusalIsNotNow() throws {
        func open(_ data: Data, _ wrapped: @escaping (Data) throws -> any OwnerKey) -> OwnerKeychain.Opened {
            OwnerKeychain.open(data, chip: true, enclave: true, wrapped: wrapped, control: Self.works)
        }
        // the first signature fails as with another chip's wrapped key, or CryptoKit cannot read the form at all
        guard case .otherMac = open(Self.wrappedForm(), { _ in Refusing(error: Self.tokenKit(-3)) }),
              case .otherMac = open(Self.wrappedForm(), { _ in throw Self.tokenKit(-8) }),
              case .otherMac = open(Self.wrappedForm(), { _ in throw Self.tokenKit(-3) }) else {
            Issue.record("a form that the chip refuses itself is another Mac's")
            return
        }
        // the token's daemon does not answer, or the keychain refuses now: not now, and the next read tries again
        let passing = Self.wrappedForm()
        guard case .notNow = open(passing, { _ in Refusing(error: Self.tokenKit(-2)) }),
              case .notNow = open(Self.wrappedForm(), { _ in throw NSError(domain: NSOSStatusErrorDomain,
                                                                           code: Int(errSecInteractionNotAllowed)) }),
              case .key = open(passing, { _ in SoftwareOwnerKey() }) else {
            Issue.record("a refusal that may pass is not now, and leaves no mark")
            return
        }
        // a wrapped form on hardware with no chip; and on a Mac with a chip, or an Intel Mac, whose token daemon does not
        // answer now (the Door area's MUST: CryptoKit's isAvailable asks that daemon, which was down on 24 November)
        var reads = 0
        let counted: (Data) throws -> any OwnerKey = { _ in reads += 1; return SoftwareOwnerKey() }
        func open(chip: Bool?) -> OwnerKeychain.Opened {
            OwnerKeychain.open(Self.wrappedForm(), chip: chip, enclave: false, wrapped: counted, control: Self.works)
        }
        guard case .otherMac = open(chip: false), case .notNow = open(chip: true), case .notNow = open(chip: nil) else {
            Issue.record("only hardware with no chip makes a wrapped form another Mac's; a daemon that is down is not now")
            return
        }
        #expect(reads == 0, "a daemon that does not answer gets no call")
        // and a new key is the chip's wherever the hardware has one: never a software key while its daemon is down
        #expect(throws: FleetKeychainItem.Failure.self) { _ = try OwnerKeychain.enclave(chip: true, available: false) }
        #expect(try OwnerKeychain.enclave(chip: true, available: true))
        #expect(try !OwnerKeychain.enclave(chip: false, available: true))
        #expect(try OwnerKeychain.enclave(chip: nil, available: true) && !OwnerKeychain.enclave(chip: nil, available: false))
        // through the lookup, the make rule takes it: a key in its place, never in place of a key or of a failure
        guard case .otherMac = OwnerKeychain.lookup(.success(Self.wrappedForm()), open: {
            open($0) { _ in Refusing(error: Self.tokenKit(-3)) }
        }) else {
            Issue.record("the lookup says otherMac")
            return
        }
        try OwnerKeychain.mayMake(.otherMac)
        try OwnerKeychain.mayMake(.none)
        #expect(throws: FleetKeychainItem.Failure.self) { try OwnerKeychain.mayMake(.key(SoftwareOwnerKey())) }
        #expect(throws: FleetKeychainItem.Failure.self) {
            try OwnerKeychain.mayMake(.notNow(FleetKeychainItem.Failure(label: "owner key", status: errSecAuthFailed)))
        }
    }

    /// **A form that CryptoKit refused reaches it once a run.** Bug: a damaged form goes to CryptoKit at each read (the
    /// vault's plan reads each minute), and each read can crash the system's token daemon, which launchd then stops
    /// restarting: every Secure Enclave key of the Mac waits with no end (measured on 24 November 2026).
    /// And **a fresh look past that mark** (`make`, at the owner's Set up only) reads it again: a chip that opens it now
    /// gives the held key back, and the mark goes. Bug: one passing refusal holds the Set up row all run, and Set up
    /// then replaces a good key with a new identity (the Door area's read).
    @Test func aRefusedFormReachesCryptoKitOnceARun() {
        let form = Self.wrappedForm()
        var reads = 0, controls = 0
        let refusing: (Data) throws -> any OwnerKey = { _ in reads += 1; throw Self.tokenKit(-8) }
        let control: () throws -> Void = { controls += 1 }
        guard case .otherMac = OwnerKeychain.open(form, chip: true, enclave: true, wrapped: refusing, control: control),
              case .otherMac = OwnerKeychain.open(form, chip: true, enclave: true, wrapped: refusing, control: control)
        else {
            Issue.record("a refused form stays another Mac's")
            return
        }
        #expect(reads == 2 && controls == 1, "the held form once more after the control, then once a run")
        var opens = 0
        let good: (Data) throws -> any OwnerKey = { _ in reads += 1; opens += 1; return SoftwareOwnerKey() }
        guard case .key = OwnerKeychain.open(form, chip: true, enclave: true, fresh: true, wrapped: good, control: control),
              case .key = OwnerKeychain.open(form, chip: true, enclave: true, wrapped: good, control: control) else {
            Issue.record("a fresh look that the chip passes gives the key, and the mark goes")
            return
        }
        #expect(reads == 4 && opens == 2 && controls == 1)
    }

    /// **The chip's refusal counts only where a new key of this chip signs at that moment, and never for a form that
    /// this chip signed with in this run** (the coordinator's validator's M1, 24 November 2026). Bugs: CryptoTokenKit's
    /// -3 or -8 while the Mac is locked, or while its token daemon restarts, is taken for another Mac's key, so the
    /// vault's install (with no press when the hub reads no vault) or Set up makes a new owner key, a new identity for
    /// the hub, over a good one; or a look at the same moment as one that proved the form puts it in both records, and
    /// the refusal wins for the rest of the run.
    @Test func aPassingRefusalNeverMakesAnotherMacsKey() {
        let refusing: (Data) throws -> any OwnerKey = { _ in Refusing(error: Self.tokenKit(-3)) }
        // the control fails: not now, and no mark, so the next look asks the chip again
        let locked = Self.wrappedForm()
        var reads = 0
        let counted: (Data) throws -> any OwnerKey = { _ in reads += 1; return Refusing(error: Self.tokenKit(-3)) }
        guard case .notNow = OwnerKeychain.open(locked, chip: true, enclave: true, wrapped: counted, control: Self.fails),
              case .notNow = OwnerKeychain.open(locked, chip: true, enclave: true, wrapped: counted, control: Self.fails),
              case .otherMac = OwnerKeychain.open(locked, chip: true, enclave: true, wrapped: counted, control: Self.works)
        else {
            Issue.record("a refusal while the control fails is not now, with no mark; with a control that works, otherMac")
            return
        }
        #expect(reads == 3, "no mark while the control failed")
        // a form that this chip signed with in this run: a later refusal is not now, also on a fresh look (make)
        let proved = Self.wrappedForm()
        var controls = 0
        let control: () throws -> Void = { controls += 1 }
        guard case .key = OwnerKeychain.open(proved, chip: true, enclave: true, wrapped: { _ in SoftwareOwnerKey() },
                                             control: control),
              case .notNow = OwnerKeychain.open(proved, chip: true, enclave: true, fresh: true, wrapped: refusing,
                                                control: control),
              case .notNow = OwnerKeychain.open(proved, chip: true, enclave: true, fresh: true,
                                                wrapped: { _ in throw Self.tokenKit(-8) }, control: control),
              case .key = OwnerKeychain.open(proved, chip: true, enclave: true, wrapped: { _ in SoftwareOwnerKey() },
                                             control: control) else {
            Issue.record("a form proved in this run is never another Mac's")
            return
        }
        #expect(controls == 0, "no control for a form proved in this run")
        // a state that ends between the refusal and the control (an unlock, the daemon back): the held form, tried once
        // more, signs, so it is the key, with no mark (the Door area's read of 25 November 2026)
        final class FailsOnce: OwnerKey, @unchecked Sendable {
            let tries = Mutex(0)
            var publicKey: String { "" }
            func sign(_ statement: String) throws -> String {
                if tries.withLock({ $0 += 1; return $0 }) == 1 { throw OwnerKeyLookupTests.tokenKit(-3) }
                return "signed"
            }
        }
        let unlocked = Self.wrappedForm()
        guard case .key = OwnerKeychain.open(unlocked, chip: true, enclave: true, wrapped: { _ in FailsOnce() },
                                             control: Self.works),
              case .key = OwnerKeychain.open(unlocked, chip: true, enclave: true, wrapped: { _ in FailsOnce() },
                                             control: Self.fails) else {
            Issue.record("a held form that signs on its second try is the key, and proved")
            return
        }
        // the statuses: a state that passes is errSecNotAvailable, so nobody takes a good key away during it; only a
        // form that cannot be read is errSecDecode, the one code of a damaged item that VAULT.md item 7 names
        func status(_ opened: OwnerKeychain.Opened) -> OSStatus? {
            if case .notNow(let status) = opened { return status }
            return nil
        }
        #expect(status(OwnerKeychain.open(Self.wrappedForm(), chip: true, enclave: true,
                                          wrapped: { _ in Refusing(error: Self.tokenKit(-2)) }, control: Self.works))
                == errSecNotAvailable)
        #expect(status(OwnerKeychain.open(Self.wrappedForm(), chip: true, enclave: true,
                                          wrapped: { _ in throw CryptoKitError.incorrectParameterSize },
                                          control: Self.works)) == errSecDecode)
        // any other CryptoKit error (an authentication failure, a wrapped CoreCrypto error) can be a passing state
        #expect(status(OwnerKeychain.open(Self.wrappedForm(), chip: true, enclave: true,
                                          wrapped: { _ in throw CryptoKitError.authenticationFailure },
                                          control: Self.works)) == errSecNotAvailable)
        #expect(status(OwnerKeychain.open(Self.wrappedForm(), chip: true, enclave: true,
                                          wrapped: { _ in Refusing(error: Self.tokenKit(-3)) }, control: Self.fails))
                == errSecNotAvailable)
        #expect(status(OwnerKeychain.open(proved, chip: true, enclave: true, fresh: true, wrapped: refusing,
                                          control: Self.works)) == errSecNotAvailable)
        // and the lookup's record: a form that a look at the same moment proved is not another Mac's
        let fleet = "fleet-\(UUID().uuidString)"
        guard case .notNow = OwnerKeychain.settle(.otherMac, digest: Data(SHA256.hash(data: proved)), fleet: fleet),
              !OwnerKeychain.isOtherMac(fleet: fleet),
              case .otherMac = OwnerKeychain.settle(.otherMac, digest: Data(SHA256.hash(data: Self.wrappedForm())),
                                                    fleet: fleet),
              OwnerKeychain.isOtherMac(fleet: fleet) else {
            Issue.record("the lookup's record keeps a proved form held, and another one as another Mac's")
            return
        }
        // a look that proves the form while another one's control runs: the refusal leaves no mark
        let raced = Self.wrappedForm()
        guard case .notNow = OwnerKeychain.open(raced, chip: true, enclave: true, wrapped: refusing, control: {
            guard case .key = OwnerKeychain.open(raced, chip: true, enclave: true, wrapped: { _ in SoftwareOwnerKey() },
                                                 control: Self.works) else {
                Issue.record("the other look proves the form")
                return
            }
        }), case .key = OwnerKeychain.open(raced, chip: true, enclave: true, wrapped: { _ in SoftwareOwnerKey() },
                                            control: Self.works) else {
            Issue.record("a form that a look at the same moment proved is not now, and stays held")
            return
        }
    }

    /// **One look at a time for each fleet** (the Door area's read of 24 November 2026). Bug: while the chip or its
    /// token daemon does not answer (one read waited 13 minutes), each vault reading of the minute starts one more look
    /// that holds a thread of the shared pool.
    @Test func oneLookAtATimeForEachFleet() async {
        let looks = OwnerKeychain.Looks()
        let gate = DispatchSemaphore(value: 0)
        let runs = Mutex(0)
        // each wait has a limit, so that a fault fails the test and never holds the test line (the coordinator's S-c)
        let body: @Sendable () -> Bool = {
            runs.withLock { $0 += 1 }
            return gate.wait(timeout: .now() + 30) == .success
        }
        func until(_ done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(30)
            while !done() {
                if Date() > end { return false }
                await Task.yield()
            }
            return true
        }
        async let first = OwnerKeychain.look(fleet: "fleet-1", in: looks, body)
        #expect(await until { runs.withLock { $0 } == 1 })
        async let second = OwnerKeychain.look(fleet: "fleet-1", in: looks, body)
        #expect(await until { looks.record.withLock { $0.callers["fleet-1"] } == 2 }, "the second caller joined it")
        #expect(await !OwnerKeychain.look(fleet: "fleet-2", in: looks) { false })      // another fleet waits for none
        gate.signal()
        let both = await [first, second]
        #expect(both == [true, true])
        #expect(runs.withLock { $0 } == 1, "the second caller waited for the look that ran")
        #expect(looks.record.withLock { $0.running.isEmpty && $0.callers.isEmpty }, "a look that ended is not kept")
        // a look after the end runs again (`isHeld` then answers from what the run knows)
        let again = await OwnerKeychain.look(fleet: "fleet-1", in: looks) { runs.withLock { $0 += 1 }; return true }
        #expect(again && runs.withLock { $0 } == 2)
    }

    /// **The public point is read before CryptoKit reads it** (the supervisor's item, step 5). CryptoKit takes the point
    /// of the entry `pub` with a `try!` of its own, and a change of any byte of that entry stopped the process. Bugs: a
    /// damaged item stops the app at each read of the owner key; or a check that takes a sound form, or a later form of
    /// Apple's, for a damaged one, which would lead every Mac to a new key. Only pure code reads the forms here: a
    /// changed form given to CryptoKit can crash the system's token daemon.
    @Test func aDamagedPointNeverReachesCryptoKit() throws {
        func der(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
            let count = value.count
            let length: [UInt8] = count < 0x80 ? [UInt8(count)]
                : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
            return [tag] + length + value
        }
        func named(_ name: String, _ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
            der(0x30, der(0x0c, Array(name.utf8)) + der(tag, value))
        }
        // the layout of a form that this Mac's chip made on 24 November 2026: an OCTET STRING, a SET, "rk" and its SET
        let point = [UInt8](P256.Signing.PrivateKey().publicKey.x963Representation)
        let entries = named("bid", 0x04, [0x00, 0x00, 0x00, 0x00]) + named("pub", 0x04, point)
            + named("rko", 0x02, [0x00]) + named("wk", 0x04, [UInt8](repeating: 0x5a, count: 40))
        let form = der(0x04, der(0x31, named("rk", 0x31, entries) + named("ed", 0x31, named("acl", 0x31, []))))
        #expect(EnclaveBlob.point(in: Data(form)) == .valid)
        let pub = try #require(form.firstRange(of: der(0x0c, Array("pub".utf8))))
        let entry = (pub.lowerBound - 2)..<(pub.upperBound + 2 + point.count)      // its SEQUENCE's head to the point
        for at in entry.dropFirst(2) {                                              // the name, the tag, the length, the point
            for change: UInt8 in [0xff, 0x01] {
                var damaged = form
                damaged[at] ^= change
                #expect(EnclaveBlob.point(in: Data(damaged)) == .damaged, "byte \(at) ^ \(change)")
            }
        }
        var damaged = form
        damaged[entry.upperBound - 1] ^= 0x01
        var reads = 0
        guard case .notNow = OwnerKeychain.open(Data(damaged), chip: true, enclave: true, wrapped: { _ in
            reads += 1
            return SoftwareOwnerKey()
        }, control: Self.works) else {
            Issue.record("a damaged point keeps the key and is not now: never a new key on a form this check misreads")
            return
        }
        #expect(reads == 0, "a damaged point never reaches CryptoKit")
        // another outer form is not this check's: CryptoKit reads it as before
        for other in [[0x05] + form.dropFirst(), [0x30, 0x00] + form, Array(form.dropLast())] {
            #expect(EnclaveBlob.point(in: Data(other)) == .unknown)
        }
        // the whole layout of a form that an Apple silicon chip made on 24 November 2026, each entry in its place, with
        // random values: no form of a real chip is in the tests (the coordinator's validator's S3 and N2)
        func random(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }
        let all = named("bid", 0x04, random(4)) + named("pub", 0x04, point) + named("rko", 0x02, [0x00])
            + named("kt", 0x02, [0x04]) + named("wk", 0x04, random(40)) + named("bc", 0x02, [0x0a])
            + named("kv", 0x02, [0x02]) + named("kid", 0x04, random(16)) + named("rkm", 0x04, random(32))
        var whole = der(0x04, der(0x31, named("rk", 0x31, all)
                                    + named("ed", 0x31, named("acl", 0x31, named("dacl", 0x01, [0x01])))))
        #expect(whole.count == 284 && EnclaveBlob.point(in: Data(whole)) == .valid)
        let at = try #require(whole.firstRange(of: der(0x0c, Array("pub".utf8)))).upperBound + 10
        whole[at] ^= 0x01
        #expect(EnclaveBlob.point(in: Data(whole)) == .damaged)
    }

    /// The one place that makes an owner key makes it only on `none`, and on `otherMac` only at the owner's Set up, the
    /// one install with no --keep-owner (a Try again of the app's own install keeps the vault's owner key, so a new key
    /// would match no pin and the Mac would never see Set up again: the Door area's read of ad139ef2c). Bugs: a later change puts back `OwnerKeychain.key(fleet:) ?? OwnerKeychain.make(fleet:)`, whose nil
    /// is also a read that failed now; or an automatic round (the install where the hub reads no vault, the update
    /// after each release) replaces another Mac's key with no press, a new identity for the hub with no word to the
    /// owner (the Door area's read of 25 November 2026).
    @Test func theInstallMakesAKeyOnlyWhereNoneIsUsable() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var makers: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("OwnerKeychain.make(") {
                makers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(makers == ["CentralVaultSection.swift: case .none: key = try OwnerKeychain.make(fleet: fleet)",
                           "CentralVaultSection.swift: case .otherMac where pressed && !own: key = try OwnerKeychain.make(fleet: fleet)"],
                "\(makers)")
        let section = try String(contentsOf: sources.appendingPathComponent("Founderizer/CentralVaultSection.swift"),
                                 encoding: .utf8)
        #expect(section.contains("case .otherMac: return .waitsForSetUp"))
        // the automatic rounds say no press, and only the owner's Set up and Try again say one
        for automatic in ["case .install: await installOwn(store, pressed: false)",
                          "case .update: await updateOwn(store, pressed: false)"] {
            #expect(section.contains(automatic), "\(automatic)")
        }
        let pressed = section.components(separatedBy: "pressed: true").count - 1
        #expect(pressed == 3, "Set up, and Try again's install and update: \(pressed)")
        #expect(section.contains("switch await model.installed(store, own: false, pressed: true)"))
    }

    /// **A moved Mac holds no key for the vault's plan**, so its row says Set up, the path of a new Mac. Bug: `isHeld`
    /// goes back to the item's presence alone, and a Mac that Migration Assistant made never gets a key of its own.
    @Test func aMovedMacHoldsNoKeyForTheVaultsPlan() {
        var reads = 0
        func lookup(_ found: OwnerKeychain.Lookup) -> () -> OwnerKeychain.Lookup { { reads += 1; return found } }
        #expect(!OwnerKeychain.isHeld(there: false, known: nil, lookup: lookup(.key(SoftwareOwnerKey()))))
        #expect(!OwnerKeychain.isHeld(there: true, known: nil, lookup: lookup(.otherMac)))
        #expect(!OwnerKeychain.isHeld(there: true, known: true, lookup: lookup(.key(SoftwareOwnerKey()))))
        #expect(OwnerKeychain.isHeld(there: true, known: false, lookup: lookup(.otherMac)))
        #expect(OwnerKeychain.isHeld(there: true, known: nil, lookup: lookup(.key(SoftwareOwnerKey()))))
        #expect(OwnerKeychain.isHeld(there: true, known: nil, lookup: lookup(.notNow(FleetKeychainItem.Failure(
            label: "owner key", status: errSecInteractionNotAllowed)))))
        #expect(reads == 3, "a read only where this run knows nothing of the item")
        // The plan's reading takes that first look off the main actor, before its facts: a chip or a token daemon that
        // does not answer (24 November 2026, after a run of crashes) must stop no window.
        let section = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/CentralVaultSection.swift")
        let text = (try? String(contentsOf: section, encoding: .utf8)) ?? ""
        let warm = text.range(of: "if let fleet = fresh?.fleetID { _ = await OwnerKeychain.look(fleet: fleet) }")
        let plan = text.range(of: "plan = VaultPlan.of(fresh, facts: facts)")
        #expect(warm != nil && plan != nil && warm!.upperBound < plan!.lowerBound, "the first look is off the main actor")
        // and the synchronous check, which the give paths call on the main actor, reads no data and signs nothing: it
        // starts that look and answers from the item's presence until it ends (the Door area's read of 25 November)
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore/OwnerKey.swift")
        let key = (try? String(contentsOf: core, encoding: .utf8)) ?? ""
        let start = key.range(of: "public static func isHeld(fleet: String) -> Bool {")
        let end = start.flatMap { key.range(of: "\n    }\n", range: $0.upperBound..<key.endIndex) }
        let body = start.flatMap { s in end.map { String(key[s.upperBound..<$0.lowerBound]) } } ?? ""
        #expect(!body.contains("lookup(") && body.contains("Task.detached { _ = await look(fleet: fleet) }"), "\(body)")
    }

    /// **The same rule for the recovery code and the owner access key** (the Door area's read of 24 November 2026), whose
    /// `kept` the vault's recovery step and the sweep call: only "not there" lets a new value in. Bugs: one failed read
    /// made a new recovery code, so the backups sealed to the old one could no longer be opened; or a new owner access
    /// key, while the fleet's copies keep the old one; or `make`'s own guard lets a value in over held data.
    @Test func aNewValueOnlyWhereTheItemIsNotThere() throws {
        let item = FleetKeychainItem(service: "com.example.test", label: "recovery code")
        try item.mayMake(Self.failed(errSecItemNotFound))
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecUserCanceled] {
            #expect(throws: FleetKeychainItem.Failure.self, "status \(status)") { try item.mayMake(Self.failed(status)) }
        }
        #expect(throws: FleetKeychainItem.Failure.self, "held data") { try item.mayMake(.success(Data([1]))) }
        let code = try RecoveryCode.make()
        guard case .value(let back) = item.held(.success(Data(code.normalized.utf8)), decode: RecoveryKeychain.decode),
              back == code else {
            Issue.record("a kept code reads back")
            return
        }
        guard case .notNow = item.held(Self.failed(errSecInteractionNotAllowed), decode: RecoveryKeychain.decode),
              case .notNow = item.held(.success(Data("not a code".utf8)), decode: RecoveryKeychain.decode),
              case .none = item.held(Self.failed(errSecItemNotFound), decode: { OwnerAccessKey(seed: $0) }) else {
            Issue.record("a read that failed now, or data that does not read, is never none")
            return
        }
        // Both `kept` go through that rule: a later change that puts back `if let … = key(fleet:)` fails here.
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore")
        for file in ["RecoveryCode.swift", "OwnerAccessKey.swift"] {
            let text = try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
            let start = try #require(text.range(of: "public static func kept(fleet: String) throws"), "\(file)")
            let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex), "\(file)")
            let body = text[start.upperBound..<end.lowerBound]
            // the keychain's answer comes first, and no read whose nil is also a failure comes before it
            let first = body.split(separator: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces)
            #expect(first == "let read = item.lookup(fleet: fleet)", "\(file): \(first ?? "")")
            #expect(body.contains("item.held(read") && body.contains("case .none: try item.mayMake(read)"), "\(file)")
        }
    }

    /// Bugs: an enclave error gives a software key on a Mac with a chip; `make` decides by CryptoKit's daemon alone
    /// again; a virtual machine on Apple silicon, which has no enclave, is taken for a Mac with a chip, so the vault's
    /// install never makes a key there (the coordinator's validator's N1); `make` replaces what is held with no fresh
    /// look; the key gets an access control, whose proof at the first look of each run would ask the owner at each
    /// launch (the Door area's read); or the chip's control makes its key otherwise than `make` (S-b).
    @Test func aSoftwareKeyOnlyOnAMacWithNoEnclave() throws {
        struct Refused: Error {}
        #expect(throws: Refused.self) { _ = try OwnerKeychain.new(enclave: true) { throw Refused() } }
        let made = try OwnerKeychain.new(enclave: false) { throw Refused() }
        #expect(made.0 is SoftwareOwnerKey && made.1.count == 32)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore/OwnerKey.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "public static func make(fleet: String) throws -> any OwnerKey {"))
        let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        let body = text[start.upperBound..<end.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Array(body.prefix(3)) == ["let found = lookup(fleet: fleet, fresh: true)",
                                          "if case .key(let held) = found { return held }", "try mayMake(found)"], "\(body)")
        #expect(body.contains("let made = try new(enclave: enclave(chip: chip, available: SecureEnclave.isAvailable)) {"))
        #expect(body.contains("try SecureEnclave.P256.Signing.PrivateKey()"), "a key with no argument: no access control")
        #expect(!text.contains("accessControl") && !text.contains("kSecAttrAccessControl"))
        let opening = try #require(text.range(of: "static func open(_ data: Data, fresh: Bool = false) -> Opened {"))
        let opened = try #require(text.range(of: "\n    }\n", range: opening.upperBound..<text.endIndex))
        #expect(text[opening.upperBound..<opened.lowerBound].contains(
            "_ = try EnclaveOwnerKey(key: SecureEnclave.P256.Signing.PrivateKey()).sign(proof)"),
            "the control makes its key with CryptoKit's default access, as make does")
        // the chip by the hardware: none in a simulator, an Apple silicon Mac's own, and in a virtual machine on Apple
        // silicon (Tart, UTM) or on an Intel Mac, CryptoKit's word
        #expect(OwnerKeychain.chip(simulator: true, arm64: true, virtual: false) == false)
        #expect(OwnerKeychain.chip(simulator: false, arm64: true, virtual: false) == true)
        #expect(OwnerKeychain.chip(simulator: false, arm64: false, virtual: false) == nil)
        // a virtual machine: CryptoKit's word, never false by the token daemon's word, which a passing fault gives
        #expect(OwnerKeychain.chip(simulator: false, arm64: true, virtual: true) == nil)
    }

    /// **A held item that no chip of this Mac opens is kept aside before a new key takes its place** (the coordinator's
    /// validator's S-a). Bugs: a wrong reading of another Mac's key replaces the owner key for good, with no way back;
    /// a copy that fails still lets the new key in; or a second replacement loses the first old form, which may be the
    /// key that the vault and the brokers still pin (the Door area's NIT).
    @Test func aMovedMacsOldItemIsKeptAside() throws {
        struct Refused: Error {}
        var kept: [Data] = []
        let form = Self.wrappedForm()
        try OwnerKeychain.keepAside(.success(form), fleet: "fleet-1", kept: { _ in false }) { data, fleet in
            #expect(fleet == "fleet-1")
            kept.append(data)
        }
        #expect(kept == [form])
        #expect(throws: FleetKeychainItem.Failure.self) {
            try OwnerKeychain.keepAside(Self.failed(errSecInteractionNotAllowed), fleet: "fleet-1",
                                        kept: { _ in false }) { data, _ in
                kept.append(data)
            }
        }
        #expect(throws: Refused.self) {
            try OwnerKeychain.keepAside(.success(form), fleet: "fleet-1", kept: { _ in false }) { _, _ in throw Refused() }
        }
        #expect(kept == [form] && OwnerKeychain.aside.service != OwnerKeychain.item.service)
        // a copy that is there already stays: the first old form may be the key that the vault still pins
        try OwnerKeychain.keepAside(.success(Self.wrappedForm()), fleet: "fleet-1", kept: { _ in true }) { data, _ in
            kept.append(data)
        }
        #expect(kept == [form])
        // make keeps it aside for otherMac alone, and before the new key is kept, so a failed copy keeps what is there
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore/OwnerKey.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let aside = try #require(text.range(of:
            "if case .otherMac = found { try keepAside(item.lookup(fleet: fleet), fleet: fleet) }"))
        let keep = try #require(text.range(of: "try item.keep(made.1, fleet: fleet)"))
        #expect(aside.upperBound < keep.lowerBound)
    }
}
