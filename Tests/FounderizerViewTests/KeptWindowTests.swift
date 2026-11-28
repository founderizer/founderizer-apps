import FleetCore
import Foundation
import Testing
@testable import Founderizer

struct KeptWindowTests {
    @Test func theDecodedLimitAlsoAppliesToAWindowThatFitsOnDisk() throws {
        let json = Data(repeating: 32, count: 8_192)
        let packed = try #require(KeptWindow.stored(json))
        #expect(packed.count < json.count - 1)
        #expect(KeptWindow.restored(packed, atMost: json.count) == json)
        #expect(KeptWindow.restored(packed, atMost: json.count - 1) == nil)
        // A wrong declared size must not turn the first part of a larger stream into a good window.
        var short = packed
        var size = UInt32(json.count - 1).bigEndian
        withUnsafeBytes(of: &size) { short.replaceSubrange(4..<8, with: $0) }
        #expect(KeptWindow.restored(short, atMost: json.count - 1) == nil)
        #expect(KeptWindow.restored(Data(packed.prefix(8))) == nil)
        let corrupt = Data(packed.prefix(8)) + Data([0xDB, 0x84, 0xFE, 0x23])
        let truncated = Data(packed.prefix(8 + (packed.count - 8) / 2))
        #expect(KeptWindow.restored(corrupt) == nil)
        #expect(KeptWindow.restored(truncated) == nil)
        // A stream can also end cleanly before its declared size.
        var incomplete = packed
        size = UInt32(json.count + 1).bigEndian
        withUnsafeBytes(of: &size) { incomplete.replaceSubrange(4..<8, with: $0) }
        #expect(KeptWindow.restored(incomplete) == nil)
    }

    @Test func aSavedWindowOverSixteenMillionDecodedBytesIsRefusedAtLaunch() throws {
        // Use a valid stream of the advertised size so only the launch limit can reject it.
        let overLimit = Data(repeating: 32, count: 16_000_001)
        let payload = try (overLimit as NSData).compressed(using: .lzfse) as Data
        var file = Data("FZW1".utf8)
        var size = UInt32(overLimit.count).bigEndian
        withUnsafeBytes(of: &size) { file.append(contentsOf: $0) }
        file.append(payload)
        #expect(KeptWindow.restored(file) == nil)
    }

    @Test @MainActor func aPlainWindowUpgradesAndTheFinalSaveRestoresTheNewestReading() throws {
        func window(_ db: String) throws -> Data {
            let fields: [String: Any] = [
                "schema_version": 1, "db": db, "time": 100, "agents": [], "tasks": [],
                "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
            ]
            // JSON permits trailing whitespace. Make the first periodic save take longer than the final one.
            return try JSONSerialization.data(withJSONObject: fields)
                + Data(repeating: 32, count: db == "periodic" ? 4 * 1024 * 1024 : 4096)
        }
        let plain = try window("plain")
        _ = ViewHost.store(try HubState.decode(plain))
        let folder = AppFolders.support.appendingPathComponent("Founderizer")
        guard folder.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            throw ViewHost.Missing(description: "Expected the test folder")
        }
        let hub = URL(string: "http://snapshot-\(UUID().uuidString).example.invalid:9")!
        let file = try #require(StartAgain.readingFiles(of: hub, in: folder).first)
        let defaults = AppDefaults.store, previous = defaults.string(forKey: "hubAddress")
        defaults.set(hub.absoluteString, forKey: "hubAddress")
        defer {
            defaults.set(previous, forKey: "hubAddress")
            try? FileManager.default.removeItem(at: file)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try plain.write(to: file)
        let store = FleetStore()
        #expect(store.state?.db == "plain")
        store.keepReading(try window("periodic"))
        let newest = try window("final")
        store.keepReading(newest)
        store.writeReading(now: true)
        let saved = try Data(contentsOf: file)
        #expect(saved.count < newest.count)
        #expect(KeptWindow.restored(saved) == newest)
        #expect(FleetStore().state?.db == "final")
    }
}
