import Foundation
import Testing
@testable import FleetCore

/// The owner's access key and its place in a copy of the fleet: the way back after a lost Mac. The key's file is
/// checked against OpenSSH's own `ssh-keygen`, and the copy with the key in it against the system's own `unzip`, so
/// neither is tested against this app's reading of what this app wrote. One test at a time: the tests of a restore's
/// file compare the folders of this Mac's temporary folder before and after.
@Suite(.serialized)
struct OwnerAccessKeyTests {
    private static let seed = Data((0..<32).map { UInt8($0 * 7 + 3) })

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("owner-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return made
    }

    private func fixtureCopy(in folder: URL) throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: "copy", withExtension: "zip", subdirectory: "Fixtures"))
        let copy = folder.appendingPathComponent("founderizer-0f1e2d3c4b5a6978-20261110T120000Z.zip")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    /// One program of the system, to its end: its exit status and what it printed.
    private func run(_ program: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: program)
        child.arguments = arguments
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        child.standardInput = FileHandle.nullDevice
        try child.run()
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    // MARK: the key

    @Test func theKeysFileIsAFileOpenSSHReads() throws {
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("owner-access.key")
        try Data(key.privateFile.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // OpenSSH makes the public half again from the private file, and it is this key's line.
        let made = try run("/usr/bin/ssh-keygen", ["-y", "-f", file.path])
        #expect(made.status == 0, "ssh-keygen said: \(made.output)")
        let parts = made.output.split(separator: " ").map(String.init)
        #expect(parts.count >= 2)
        #expect(key.publicLine.hasPrefix(parts.prefix(2).joined(separator: " ") + " "))
        #expect(key.publicLine.hasSuffix(" " + OwnerAccessKey.comment))
        // And its fingerprint is the one OpenSSH prints.
        let print = try run("/usr/bin/ssh-keygen", ["-l", "-f", file.path])
        #expect(print.status == 0)
        #expect(print.output.contains(key.fingerprint))
    }

    @Test func aFileGivesItsKeyBackAndIsTheSameFileEachTime() throws {
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        #expect(OwnerAccessKey(privateFile: key.privateFile) == key)
        #expect(key.privateFile == OwnerAccessKey(seed: Self.seed)?.privateFile)
        #expect(key.privateFile.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(key.privateFile.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        #expect(key.privateFile.split(separator: "\n").allSatisfy { $0.count <= 70 })
        let other = try OwnerAccessKey.make()
        #expect(other != key)
        #expect(OwnerAccessKey(privateFile: other.privateFile) == other)
    }

    @Test func aKeyThatOpenSSHMadeIsRead() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("made")
        let made = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "a comment of its own", "-f", file.path])
        #expect(made.status == 0, "ssh-keygen said: \(made.output)")
        let key = try #require(OwnerAccessKey(privateFile: try String(contentsOf: file, encoding: .utf8)))
        let line = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
        #expect(line.split(separator: " ").prefix(2).joined(separator: " ")
                == key.publicLine.split(separator: " ").prefix(2).joined(separator: " "))
    }

    @Test func whatIsNoKeyOfThisKindIsNoKey() throws {
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        #expect(OwnerAccessKey(seed: Data(repeating: 1, count: 31)) == nil)
        #expect(OwnerAccessKey(privateFile: "") == nil)
        #expect(OwnerAccessKey(privateFile: "not a key at all") == nil)
        #expect(OwnerAccessKey(privateFile: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n") == nil)
        // The file of one key with one character of its middle changed: the two halves no longer belong together, or
        // the file no longer reads at all.
        var lines = key.privateFile.split(separator: "\n").map(String.init)
        let middle = lines.count / 2
        lines[middle] = String(lines[middle].dropFirst()) + (lines[middle].hasPrefix("A") ? "B" : "A")
        #expect(OwnerAccessKey(privateFile: lines.joined(separator: "\n") + "\n") != key)
        // A key with a passphrase is another kind of file, and so is a key of another kind.
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let locked = folder.appendingPathComponent("locked")
        #expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "a passphrase", "-f", locked.path]).status == 0)
        #expect(OwnerAccessKey(privateFile: try String(contentsOf: locked, encoding: .utf8)) == nil)
        let ecdsa = folder.appendingPathComponent("ecdsa")
        #expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-N", "", "-f", ecdsa.path]).status == 0)
        #expect(OwnerAccessKey(privateFile: try String(contentsOf: ecdsa, encoding: .utf8)) == nil)
    }

    @Test func theKeyPrintsAsNothing() throws {
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        var dumped = ""
        dump(key, to: &dumped)
        let secret = key.seed.base64EncodedString()
        for text in ["\(key)", String(describing: key), String(reflecting: key), dumped] {
            #expect(!text.contains(secret))
            #expect(!text.contains("PRIVATE KEY"))
        }
        #expect("\(key)" == "OwnerAccessKey")
    }

    // MARK: the key's line on a server

    @Test func theLineGoesIntoRootsFileOnceAndNothingElseChanges() throws {
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A server whose root has no key folder yet: the folder and the file are made, for root alone.
        let fresh = folder.appendingPathComponent("fresh/.ssh/authorized_keys")
        let first = try run("/bin/sh", ["-c", OwnerAccess.install(key, file: fresh.path)])
        #expect(first.status == 0, "sh said: \(first.output)")
        #expect(OwnerAccess.isInPlace(first.output))
        #expect(try String(contentsOf: fresh, encoding: .utf8) == key.publicLine + "\n")
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        // A second run says the same and adds nothing.
        let second = try run("/bin/sh", ["-c", OwnerAccess.install(key, file: fresh.path)])
        #expect(OwnerAccess.isInPlace(second.output))
        #expect(try String(contentsOf: fresh, encoding: .utf8) == key.publicLine + "\n")
        // A file that holds the app's own key and does not end with a new line keeps that key on its own line.
        let held = folder.appendingPathComponent("held")
        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfThisServerThatStaysAsItIs000000000 founderizer@Studio"
        try Data(other.utf8).write(to: held)
        let third = try run("/bin/sh", ["-c", OwnerAccess.install(key, file: held.path)])
        #expect(OwnerAccess.isInPlace(third.output))
        #expect(try String(contentsOf: held, encoding: .utf8) == other + "\n" + key.publicLine + "\n")
        // What a server says when it could not write is not the mark.
        #expect(!OwnerAccess.isInPlace("sudo: a password is required"))
        #expect(!OwnerAccess.isInPlace("not-" + OwnerAccess.inPlace))
        #expect(OwnerAccess.install(key).contains(OwnerAccess.rootKeys))
    }

    // MARK: the key in a copy

    @Test func theCheckOfAMembersBytesIsTheOneEveryZipCarries() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test func aCopyTakesOneMemberMoreAndStaysACopy() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let before = try ZipArchive.names(in: copy)
        let manifest = try ChosenCopy.read(copy).manifest
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        #expect(try ZipArchive.add(Data(key.privateFile.utf8), named: OwnerAccess.member, to: copy))
        // Every member of before is there and reads as before, and the new one is the last.
        #expect(try ZipArchive.names(in: copy) == before + [OwnerAccess.member])
        #expect(try ChosenCopy.read(copy).manifest == manifest)
        #expect(try ZipArchive.member(OwnerAccess.member, in: copy, limit: 4096) == Data(key.privateFile.utf8))
        // The system's own reader checks every member of it, the new one too.
        let checked = try run("/usr/bin/unzip", ["-tq", copy.path])
        #expect(checked.status == 0, "unzip said: \(checked.output)")
        // So does the reader that the hub's restore uses, Python's own.
        let python = try run("/usr/bin/python3", ["-c", """
            import sys, zipfile
            z = zipfile.ZipFile(sys.argv[1])
            assert z.testzip() is None
            sys.stdout.write(z.read(sys.argv[2]).decode())
            """, copy.path, OwnerAccess.member])
        #expect(python.status == 0, "python said: \(python.output)")
        #expect(python.output == key.privateFile)
        // And what it takes out is a key file that OpenSSH reads, for its owner alone.
        #expect(try run("/usr/bin/unzip", ["-q", "-o", copy.path, OwnerAccess.member, "-d", folder.path]).status == 0)
        let out = folder.appendingPathComponent(OwnerAccess.member)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        #expect(try run("/usr/bin/ssh-keygen", ["-y", "-f", out.path]).status == 0)
        // A second time adds nothing.
        let size = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber
        #expect(try ZipArchive.add(Data("another".utf8), named: OwnerAccess.member, to: copy) == false)
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber == size)
    }

    @Test func theCopyThatHeKeepsCarriesTheKeyOfItsOwnFleet() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let untouched = try Data(contentsOf: copy)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        #expect(OwnerAccess.key(in: copy) == nil)
        var asked: [String] = []
        let made = try #require(OwnerAccess.withKey(copy) { fleet in asked.append(fleet); return key })
        // The key is the one of the fleet that the copy's own manifest names.
        #expect(asked == [try ChosenCopy.read(copy).manifest.fleet_id])
        let found = try #require(OwnerAccess.key(in: made))
        #expect(found.fleet == asked[0])
        #expect(found.key == key)
        // The copy itself is as the hub served it: the key went into a second file beside it.
        #expect(made != copy)
        #expect(made.deletingLastPathComponent() == copy.deletingLastPathComponent())
        #expect(try Data(contentsOf: copy) == untouched)
    }

    /// **A copy of any size is read as a copy and takes the key** (the owner, 22 November 2026: "why is there a backup
    /// limit? it shouldn't?"). The app refused a copy of more than 256 MiB in `ChosenCopy.read`, which the key's own
    /// step reads too, so a copy that large was kept with no key and no word about it (`withKey` gave nil). The copy here
    /// is a real ZIP of 300 MiB of records that Python's own `zipfile` writes, its records a hole on the disk, so the
    /// test writes no 300 MiB. The bug that it catches: a limit of size left in one reader of the app.
    @Test func aCopyOfAnySizeIsReadAsACopyAndTakesTheKey() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = try ZipArchive.member(FleetManifest.manifestMember, in: try fixtureCopy(in: folder), limit: 1 << 20)
        let copy = folder.appendingPathComponent("founderizer-0f1e2d3c4b5a6978-20261122T120000Z.zip")
        let made = try run("/usr/bin/python3", ["-c", """
            import hashlib, json, sys, zipfile
            path, manifest, size, zero = sys.argv[1], json.loads(sys.argv[2]), 300 << 20, bytes(1 << 20)
            records = hashlib.sha256()
            for _ in range(size // len(zero)):
                records.update(zero)
            manifest["files"] = {"fleet.sqlite3": {"bytes": size, "sha256": records.hexdigest()}}
            class Holes:
                # a file whose parts of zeros are holes: the copy is 300 MiB long and takes no 300 MiB of the disk
                def __init__(self, f): self.f = f
                def write(self, data):
                    if data and not data.strip(b"\\0"):
                        self.f.seek(len(data), 1)
                        return len(data)
                    return self.f.write(data)
                def __getattr__(self, name): return getattr(self.f, name)
            with open(path, "wb") as f, zipfile.ZipFile(Holes(f), "w", zipfile.ZIP_STORED) as z:
                z.writestr("fleet.json", json.dumps(manifest))
                with z.open(zipfile.ZipInfo("fleet.sqlite3", date_time=(1980, 1, 1, 0, 0, 0)), "w") as member:
                    for _ in range(size // len(zero)):
                        member.write(zero)
            """, copy.path, String(decoding: manifest, as: UTF8.self)])
        #expect(made.status == 0, "python said: \(made.output)")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber).int64Value
        #expect(size > 300 << 20)
        let chosen = try ChosenCopy.read(copy)
        #expect(chosen.bytes == size)
        #expect(chosen.manifest.files[FleetManifest.recordsMember]?.bytes == 300 << 20)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let kept = try #require(OwnerAccess.withKey(copy) { _ in key })
        #expect(OwnerAccess.key(in: kept)?.key == key)
        #expect(try ZipArchive.names(in: kept) == [FleetManifest.manifestMember, FleetManifest.recordsMember,
                                                    OwnerAccess.member])
    }

    /// **A copy of a later hub takes the key** (the audit's finding 1, 24 November 2026). The key's step read the copy's
    /// manifest with the restore's own check (format 1, a fixed list of members), and the hub releases before the app:
    /// a hub that added a member to the manifest would have made every older Mac keep its copies with no key and no word,
    /// until the last copy with the key went. Here the manifest is of format 2 and lists a member that this app does not
    /// know: the restore's check refuses it, and the form check and the key go in all the same, for the fleet that it
    /// names. The bugs that it catches: the key's step reads more of the manifest than the fleet; the form check refuses
    /// a member by a list of names (the validator's M1 of 26 November 2026: every older Mac would refuse every copy).
    @Test func aCopyOfALaterHubTakesTheKey() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("founderizer-0f1e2d3c4b5a6978-20261125T120000Z.zip")
        let made = try run("/usr/bin/python3", ["-c", """
            import json, sys, zipfile
            source, path = zipfile.ZipFile(sys.argv[1]), sys.argv[2]
            manifest = json.loads(source.read("fleet.json"))
            manifest["format"] = 2
            manifest["files"]["later/member.json"] = {"bytes": 2, "sha256": "0" * 64}
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
                for name in source.namelist():
                    z.writestr(name, json.dumps(manifest) if name == "fleet.json" else source.read(name))
                z.writestr("later/member.json", "{}")
            """, try fixtureCopy(in: folder).path, copy.path])
        #expect(made.status == 0, "python said: \(made.output)")
        #expect(throws: RestoreError.otherFormat(2)) { try ChosenCopy.read(copy) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        var asked: [String] = []
        let form = try OwnerAccess.checkHubForm(copy)
        let kept = try #require(OwnerAccess.withKey(form) { fleet in asked.append(fleet); return key })
        #expect(asked == ["0f1e2d3c4b5a6978"])
        #expect(OwnerAccess.key(in: kept)?.key == key)
        #expect(OwnerAccess.key(in: kept)?.fleet == "0f1e2d3c4b5a6978")
    }

    @Test func aKeyThatCannotBeHadCostsNoCopy() throws {
        struct NoKeychain: Error {}
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let untouched = try Data(contentsOf: copy)
        #expect(OwnerAccess.withKey(copy) { _ in throw NoKeychain() } == nil)
        #expect(try Data(contentsOf: copy) == untouched)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [copy.lastPathComponent])
        // A file that is no copy of a fleet gets no key either.
        let prose = folder.appendingPathComponent("prose.zip")
        try Data("this is not a zip".utf8).write(to: prose)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        #expect(OwnerAccess.withKey(prose) { _ in key } == nil)
        #expect(OwnerAccess.key(in: prose) == nil)
    }

    // MARK: the key never goes to a hub

    /// The folders of a restore's file in this Mac's temporary folder.
    private static func restoreFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("founderizer-restore-") })
    }

    /// **A restore sends no key** (the Door area's read of 25 November 2026): the copy that this Mac keeps carries the
    /// fleet's access key, which is root on every server, and `POST /ui/restore` sent that file whole, so the key lay on
    /// the hub's disk, in a folder of its user, for the restore's time. What goes up now is the hub's own copy again,
    /// byte for byte, and the file it went from is gone after the send. The bug: the upload is the kept copy itself.
    @Test func aRestoreSendsTheCopyWithoutTheKey() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let kept = try #require(OwnerAccess.withKey(copy) { _ in key })
        let keptBytes = try Data(contentsOf: kept)
        let before = Self.restoreFolders()
        let state = RestoreHub.hub("restore-\(UUID().uuidString.lowercased()).test")
        let receipt = try await HubClient().restore(copy: kept, hub: URL(string: "http://\(state.host):8765")!,
                                                    database: "generation", client: "founderizer-swift/1/test",
                                                    requestID: UUID(), replace: false,
                                                    protocolClasses: [RestoreHub.self])
        #expect(receipt.ok)
        let sent = try #require(state.body)
        #expect(sent == (try Data(contentsOf: copy)), "what went up is not the hub's own copy")
        #expect(sent.range(of: Data(key.privateFile.utf8)) == nil, "the key's file went up")
        // The kept copy is as it was, with its key; the file that went up was in a folder of its own, which is gone.
        #expect(try Data(contentsOf: kept) == keptBytes)
        #expect(OwnerAccess.key(in: kept)?.key == key)
        let made = state.folders.subtracting(before)
        #expect(made.count == 1, "the upload came from no file of its own")
        #expect(Self.restoreFolders().isDisjoint(with: made))
        // A copy with no key goes as it is.
        #expect(try OwnerAccess.withoutKey(copy) { _ in nil } == nil)
    }

    /// The key goes under any spelling of its name and from a copy that another program wrote again (a prefix, data
    /// descriptors, a comment, deflated members), and every member that stays reads whole; the source is not touched.
    /// But it goes only with a member that ends where the directory starts, where `add` writes the key: a copy whose key
    /// members are all in the middle is not one that this app made, and sends nothing (the pin of the Door area's
    /// third read, against a hub that hid the key's entry behind one of its own).
    @Test func theKeyGoesOnlyWhereTheAppWritesIt() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        // The names that a reader or this Mac's disk writes as the top-level file, and the ones that it does not.
        for name in ["owner-access.key", "./Owner-Access.KEY", "/owner-access.key", ".\\owner-access.key",
                     "../owner-access.key", "a/../owner-access.key", "a/b/../../owner-access.key",
                     "a/../../owner-access.key", "x/./../owner-access.key", "..\\owner-access.key",
                     "owner-access.key/", "owner-access.key/x", "owner-access.key/x/..", "owner-access.key/./",
                     "C:owner-access.key", "C:\\owner-access.key", "c:/Owner-Access.key",
                     "owner-acce\u{DF}.key",
                     "owner-acce\u{17F}s.key", "owner-access.\u{212A}ey", "owner-access.key\u{0}x"] {
            #expect(OwnerAccess.isKey(name), "\(name)")
        }
        for name in ["config/skills/x/owner-access.key", "a/owner-access.key", "a/b/../owner-access.key",
                     "owner-access.key.txt",
                     "my-owner-access.key", "x\u{0600}/owner-access.key"] {
            #expect(!OwnerAccess.isKey(name), "\(name)")
        }
        for last in [true, false] {
            let zip = folder.appendingPathComponent("hand-made-\(last).zip")
            let made = try run("/usr/bin/python3", ["-c", """
                import sys, zipfile
                class Stream:                       # a file it cannot seek in: zipfile writes data descriptors (bit 3)
                    def __init__(self, f): self.f, self.n = f, 0
                    def write(self, b): self.n += len(b); return self.f.write(b)
                    def tell(self): return self.n
                    def flush(self): self.f.flush()
                with open(sys.argv[1], "wb") as f:
                    prefix = b"#!/bin/sh\\nexit 0\\n"        # a prefix, as a self-extracting archive has
                    f.write(prefix)
                    s = Stream(f)
                    s.n = len(prefix)                       # the places in the zip count from the file's start
                    with zipfile.ZipFile(s, "w") as z:
                        z.comment = b"a comment"
                        z.writestr("first.txt", "one" * 50, compress_type=zipfile.ZIP_STORED)
                        z.writestr(sys.argv[2], sys.argv[3], compress_type=zipfile.ZIP_STORED)
                        z.writestr("second.txt", "two" * 5000, compress_type=zipfile.ZIP_DEFLATED)
                        z.writestr("./Owner-Access.KEY", sys.argv[3], compress_type=zipfile.ZIP_DEFLATED)
                        z.writestr("owner-access.keyQx", sys.argv[3], compress_type=zipfile.ZIP_STORED)
                        z.writestr("config/skills/x/owner-access.key", "a skill", compress_type=zipfile.ZIP_STORED)
                        z.writestr("third/x.json", "{}", compress_type=zipfile.ZIP_STORED)
                        if sys.argv[4] == "true":
                            z.writestr("Owner-Access.Key", sys.argv[3], compress_type=zipfile.ZIP_STORED)
                data = open(sys.argv[1], "rb").read()       # a name that unzip writes to its NUL: owner-access.key
                open(sys.argv[1], "wb").write(data.replace(b"owner-access.keyQx", b"owner-access.key\\x00x"))
                """, zip.path, OwnerAccess.member, key.privateFile, String(last)])
            #expect(made.status == 0, "python said: \(made.output)")
            let source = try Data(contentsOf: zip)
            guard last else {
                #expect(throws: RestoreError.notACopy) { _ = try OwnerAccess.withoutKey(zip) { _ in nil } }
                #expect(try Data(contentsOf: zip) == source)
                continue
            }
            let plain = try #require(try OwnerAccess.withoutKey(zip) { _ in nil })
            defer { try? FileManager.default.removeItem(at: plain.deletingLastPathComponent()) }
            let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue }
            #expect(mode(plain.deletingLastPathComponent().path) == 0o700)
            #expect(mode(plain.path) == 0o600)
            // a file of that name in a folder (an agent's skill file) is another file, and stays
            #expect(try ZipArchive.names(in: plain) == ["first.txt", "second.txt", "config/skills/x/owner-access.key",
                                                        "third/x.json"])
            #expect(try Data(contentsOf: plain).range(of: Data(key.privateFile.utf8)) == nil)
            let python = try run("/usr/bin/python3", ["-c", """
                import sys, zipfile
                z = zipfile.ZipFile(sys.argv[1])
                assert z.testzip() is None and z.comment == b"a comment", z.comment
                assert z.read("second.txt") == b"two" * 5000 and z.read("first.txt") == b"one" * 50
                assert z.read("third/x.json") == b"{}"
                """, plain.path])
            #expect(python.status == 0, "python said: \(python.output)")
            #expect(try run("/usr/bin/unzip", ["-tq", plain.path]).status == 0)
            #expect(try Data(contentsOf: zip) == source)            // the source is only read
        }
    }

    /// **The fleet's own key goes nowhere, whatever member holds its bytes**: the Mac knows that key (its keychain),
    /// and a copy whose other member carries its bytes sends nothing, as a hub's hidden entry would (the third read).
    @Test func theFleetsOwnKeyGoesInNoMember() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let kept = try #require(OwnerAccess.withKey(copy) { _ in key })
        let plain = try #require(try OwnerAccess.withoutKey(kept) { _ in key })
        try FileManager.default.removeItem(at: plain.deletingLastPathComponent())
        // The same copy with the fleet's key in a member of another name, and a key of the hub's under the key's own
        // name, last: only the fleet's own key, which this Mac knows, finds it.
        let planted = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 5 + 9) })))
        let hiding = folder.appendingPathComponent("hiding.zip")
        let made = try run("/usr/bin/python3", ["-c", """
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1]) as z:
                members = [(n, z.read(n)) for n in z.namelist()]
            with zipfile.ZipFile(sys.argv[2], "w") as z:
                for n, b in members:
                    if n == sys.argv[3]:
                        z.writestr("notes.txt", b, compress_type=zipfile.ZIP_STORED)
                        b = sys.argv[4].encode()
                    z.writestr(n, b, compress_type=zipfile.ZIP_STORED)
            """, kept.path, hiding.path, OwnerAccess.member, planted.privateFile])
        #expect(made.status == 0, "python said: \(made.output)")
        let before = Self.restoreFolders()
        #expect(throws: RestoreError.notACopy) { _ = try OwnerAccess.withoutKey(hiding) { _ in key } }
        #expect(Self.restoreFolders().subtracting(before).isEmpty, "a refused copy left a file")
        // A Mac that does not hold the key cannot look for it; there the pin alone guards, which suffices because no
        // `add` writes the key into another member's bytes and a hub never holds the fleet's key to put it there.
    }

    /// **A copy that a hub crafted sends nothing** (the Door area's second read): a member whose place in the directory
    /// is one byte past the directory's old start, where `add` then writes the key. Cut by the next member's place, the
    /// key's record stayed whole in what went up. Members are now cut by their own headers, and a place that is not a
    /// member's header refuses the copy: nothing goes, and no file of it stays on this Mac.
    @Test func aCraftedCopySendsNothing() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        // One byte past the directory's old start (inside the key's header), and on it (the key's own header).
        for past in [1, 0] {
            let zip = folder.appendingPathComponent("crafted-\(past).zip")
            let made = try run("/usr/bin/python3", ["-c", """
                import struct, sys, zipfile
                with zipfile.ZipFile(sys.argv[1], "w") as z:
                    z.writestr("a.txt", "a" * 100, compress_type=zipfile.ZIP_STORED)
                    z.writestr("x.bin", "x" * 10, compress_type=zipfile.ZIP_STORED)
                data = bytearray(open(sys.argv[1], "rb").read())
                end = data.rfind(b"PK\\x05\\x06")
                start = struct.unpack_from("<I", data, end + 16)[0]
                at = start
                while data[at:at + 4] == b"PK\\x01\\x02":
                    n, e, c = struct.unpack_from("<HHH", data, at + 28)
                    if data[at + 46:at + 46 + n] == b"x.bin":
                        struct.pack_into("<I", data, at + 42, start + int(sys.argv[2]))
                    at += 46 + n + e + c
                open(sys.argv[1], "wb").write(bytes(data))
                """, zip.path, String(past)])
            #expect(made.status == 0, "python said: \(made.output)")
            #expect(try ZipArchive.add(Data(key.privateFile.utf8), named: OwnerAccess.member, to: zip))
            let before = Self.restoreFolders()
            #expect(throws: RestoreError.notACopy, "\(past)") { _ = try OwnerAccess.withoutKey(zip) { _ in nil } }
            #expect(Self.restoreFolders().subtracting(before).isEmpty, "a refused copy left a file")
        }
    }

    /// **A copy that is locked, read only or a link is only read** (the Door area's first read): a clone keeps the
    /// file's lock, mode and access list, so a restore that worked before stopped, and a clone with the key stayed; a
    /// link was written through into the kept copy itself.
    @Test func aLockedOrLinkedCopyIsOnlyRead() throws {
        let folder = try folder()
        let copy = try fixtureCopy(in: folder)
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let kept = try #require(OwnerAccess.withKey(copy) { _ in key })
        defer {
            try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o600], ofItemAtPath: kept.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let link = folder.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: kept)
        try FileManager.default.setAttributes([.posixPermissions: 0o444, .immutable: true], ofItemAtPath: kept.path)
        let keptBytes = try Data(contentsOf: kept)
        for chosen in [kept, link] {
            let plain = try #require(try OwnerAccess.withoutKey(chosen) { _ in key })
            #expect(try Data(contentsOf: plain) == (try Data(contentsOf: copy)))
            try FileManager.default.removeItem(at: plain.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: kept) == keptBytes)
        #expect(OwnerAccess.key(in: kept)?.key == key)
    }

    /// **No hub puts its own key into a copy that the owner keeps**: a copy that carries a member of the key's name
    /// already kept it, since `add` adds nothing over a name that is there, and the owner's way back after a lost Mac
    /// took that key as root's on the new server. Now the hub's member stays out and the fleet's own key goes in.
    @Test func aKeptCopyCarriesTheFleetsKeyAndNoneOfTheHubs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        let planted = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 5 + 9) })))
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let added = try run("/usr/bin/python3", ["-c", """
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1], "a") as z:
                z.writestr(sys.argv[2], sys.argv[3])
                z.writestr("./OWNER-ACCESS.key", sys.argv[3])
            """, copy.path, OwnerAccess.member, planted.privateFile])
        #expect(added.status == 0, "python said: \(added.output)")
        let kept = try #require(OwnerAccess.withKey(copy) { _ in key })
        #expect(OwnerAccess.key(in: kept)?.key == key)
        #expect(try ZipArchive.names(in: kept).filter(OwnerAccess.isKey) == [OwnerAccess.member])
        #expect(try Data(contentsOf: kept).range(of: Data(planted.privateFile.utf8)) == nil)
        // The owner keeps no such copy at all: the hub's copy is not in the one form that a hub writes.
        #expect(throws: FleetCopyError.self) { try OwnerAccess.checkHubForm(copy) }
    }

    /// **A hub's copy is kept only in the one form that a hub writes** (the validator's read of 25 November 2026): a
    /// member that the directory does not name, here a whole local member of the key's name after the last member,
    /// is one that ditto writes as owner-access.key while this app's reader and unzip -p see the Mac's key. Such a copy is
    /// not kept; the hub's own copy, in its form, is, with the fleet's key.
    @Test func aCopyIsKeptOnlyInTheFormThatAHubWrites() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let planted = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 5 + 9) })))
        let copy = try fixtureCopy(in: folder)
        #expect(HubCopyForm.fault(copy.path) == nil, "the hub's own copy is in its form")
        let hidden = folder.appendingPathComponent("hidden.zip")
        let made = try run("/usr/bin/python3", ["-c", """
            import struct, sys, zipfile, zlib
            data = bytearray(open(sys.argv[1], "rb").read())
            end = data.rfind(b"PK\\x05\\x06")
            start = struct.unpack_from("<I", data, end + 16)[0]
            text = sys.argv[3].encode()
            body = zlib.compressobj(9, zlib.DEFLATED, -15)
            packed = body.compress(text) + body.flush()
            name = sys.argv[4].encode()
            local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 8, 0, 0, zlib.crc32(text), len(packed), len(text),
                                len(name), 0) + name + packed
            data[start:start] = local                          # after the last member, before the directory
            end += len(local)
            struct.pack_into("<I", data, end + 16, start + len(local))
            open(sys.argv[2], "wb").write(bytes(data))
            """, copy.path, hidden.path, planted.privateFile, OwnerAccess.member])
        #expect(made.status == 0, "python said: \(made.output)")
        #expect(try ZipArchive.names(in: hidden) == (try ZipArchive.names(in: copy)), "this app's reader sees no more")
        #expect(HubCopyForm.fault(hidden.path) != nil)
        #expect(throws: FleetCopyError.self) { try OwnerAccess.checkHubForm(hidden) }
        try OwnerAccess.checkHubForm(copy)
        #expect(OwnerAccess.key(in: try #require(OwnerAccess.withKey(copy) { _ in key }))?.key == key)
    }

    /// **The key's step takes only the file that passed the form check** (the validator's S1 of 26 November 2026): a
    /// file that changed after the check, or another file in its place, is not keyed and not kept. The bug that it
    /// catches: the caller keeps the hub's own file, which no check read, when the key could not go in.
    @Test func theKeyStepTakesOnlyTheFileThatPassedTheForm() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let copy = try fixtureCopy(in: folder)
        let form = try OwnerAccess.checkHubForm(copy)
        #expect(try OwnerAccess.keyed(form) { _ in key }.file != nil)
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(throws: FleetCopyError.self) { try OwnerAccess.keyed(form) { _ in key } }
    }

    /// **The form check refuses a member by what is unsafe in its name, never by a list** (the validator's M1 of 26
    /// November 2026, one rule with the Setup area's CopyShape): a name whose last part is the key's or its public half's,
    /// in any case and folder, or one that is not a plain name, is refused; a member that this app does not know is kept.
    /// The bugs that it catches: a list of names again, which refuses every copy of a later hub; a rule that lets a
    /// dotted, slashed, colon or case twin of the key's name through.
    @Test func theFormRefusesUnsafeNamesAndNoOther() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try fixtureCopy(in: folder)
        func with(_ name: String) throws -> URL {
            let out = folder.appendingPathComponent("named-\(UUID().uuidString).zip")
            let made = try run("/usr/bin/python3", ["-c", """
                import sys, zipfile
                src, out, name = sys.argv[1:4]
                with zipfile.ZipFile(src) as source, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
                    for member in source.namelist():
                        z.writestr(member, source.read(member))
                    z.writestr(name, "x")
                """, copy.path, out.path, name])
            #expect(made.status == 0, "python said: \(made.output)")
            return out
        }
        for name in ["owner-access.key", "Owner-Access.Key", "./owner-access.key", "a/../owner-access.key",
                     "/C:/owner-access.key", "C:owner-access.key", "owner-access.key/../x", "a\\b", "a//b", "a/./b",
                     "caf\u{e9}.txt", "with space", "notes/owner-access.key", "a/OWNER-ACCESS.PUB", "owner-access.key.",
                     "a/Owner-Access.Pub..."] {
            #expect(HubCopyForm.fault(try with(name).path) != nil, "\(name) is refused")
        }
        for name in ["later/member.json", "vault/central.json", "config/new-kind.toml", "a/.../b"] {
            let kept = try with(name)
            #expect(HubCopyForm.fault(kept.path) == nil, "\(name) is kept")
            #expect(throws: Never.self) { try OwnerAccess.checkHubForm(kept) }
        }
    }

    /// **A hub that makes the key's step fail keeps no key of its own with the owner** (the Door area's second read):
    /// the callers kept the hub's file as it was when `withKey` gave nil, and a hub can make it give nil, with a
    /// manifest that lists a member of the key's name or with members that overlap. Such a copy is not kept at all,
    /// and a copy with no such member is kept as the hub gave it.
    @Test func aCopyThatCannotTakeTheFleetsKeyKeepsNoKeyOfTheHubs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try #require(OwnerAccessKey(seed: Self.seed))
        let planted = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 5 + 9) })))
        // A copy whose manifest lists a member of the key's name, which the hub put in: withKey gives nil.
        let copy = try fixtureCopy(in: folder)
        let made = try run("/usr/bin/python3", ["-c", """
            import hashlib, json, sys, zipfile
            src, out, name, text = sys.argv[1:5]
            with zipfile.ZipFile(src) as z:
                members = {n: z.read(n) for n in z.namelist()}
            manifest = json.loads(members["fleet.json"])
            manifest["files"][name] = {"bytes": len(text), "sha256": hashlib.sha256(text.encode()).hexdigest()}
            members["fleet.json"] = json.dumps(manifest).encode()
            members[name] = text.encode()
            with zipfile.ZipFile(out, "w") as z:
                for n, b in members.items():
                    z.writestr(n, b)
            """, copy.path, folder.appendingPathComponent("listed.zip").path, OwnerAccess.member, planted.privateFile])
        #expect(made.status == 0, "python said: \(made.output)")
        let listed = folder.appendingPathComponent("listed.zip")
        #expect(OwnerAccess.withKey(listed) { _ in key } == nil)
        #expect(throws: FleetCopyError.self) { try OwnerAccess.checkHubForm(listed) }
        // A small file that this app's reader does not take is not kept either; a copy with no key member is.
        let prose = folder.appendingPathComponent("prose.zip")
        try Data("not a zip".utf8).write(to: prose)
        #expect(throws: FleetCopyError.self) { try OwnerAccess.checkHubForm(prose) }
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let plain = try fixtureCopy(in: other)
        try OwnerAccess.checkHubForm(plain)
        #expect(OwnerAccess.key(in: try #require(OwnerAccess.withKey(plain) { _ in key }))?.key == key)
    }
}

/// **A stand-in for the hub's `POST /ui/restore`**, which opens no port: it keeps the body that came, and the folders
/// of a restore's file in the temporary folder at that moment, and answers as the hub does.
final class RestoreHub: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let host: String
        var body: Data?
        var folders: Set<String> = []
        init(host: String) { self.host = host }
    }
    nonisolated(unsafe) private static var hubs: [String: State] = [:]
    private static let lock = NSLock()

    static func hub(_ host: String) -> State {
        lock.lock(); defer { lock.unlock() }
        let state = State(host: host)
        hubs[host] = state
        return state
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let state = Self.hubs[request.url?.host ?? ""]
        Self.lock.unlock()
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        state?.body = body
        state?.folders = Set(((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
            .filter { $0.hasPrefix("founderizer-restore-") })
        let json = #"{"ok": true, "fleet_id": "0f1e2d3c4b5a6978", "made_at": null, "records_bytes": 18816, "files": [], "changed": [], "removed": [], "keep_replaced": false, "restarting": true, "replayed": null}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
