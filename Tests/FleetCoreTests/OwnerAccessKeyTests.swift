import Foundation
import Testing
@testable import FleetCore

/// The owner's access key and its place in a copy of the fleet: the way back after a lost Mac. The key's file is
/// checked against OpenSSH's own `ssh-keygen`, and the copy with the key in it against the system's own `unzip`, so
/// neither is tested against this app's reading of what this app wrote.
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
}
