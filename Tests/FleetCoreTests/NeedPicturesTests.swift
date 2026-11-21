import Foundation
import Testing
@testable import FleetCore

/// **Pictures as the options of a Needs-you item** (owner feature `need_pictures`, API 1.285; the owner's "Yes, as
/// drawn" of 21 November 2026). The hub raises such an item only while each of his apps says on its reads that it draws
/// them, and the card draws a picture over an option only when there is one picture for each option.
struct NeedPicturesTests {
    private static let now = Int(Date().timeIntervalSince1970)

    private func picture(_ id: Int) -> [String: Any] {
        ["id": id, "name": "ad-\(id).png", "mime": "image/png", "size": 1200, "sha256": String(repeating: "a", count: 64),
         "created": Self.now - 60, "kept": NSNull()]
    }

    private func need(options: [String], pictures: [Int]?, extra: [String: Any] = [:],
                      mime: String = "image/png") throws -> OwnerNeed {
        let files: Any = pictures.map { $0.map { picture($0).merging(["mime": mime]) { _, new in new } } } ?? NSNull()
        let row: [String: Any] = ["id": 4, "title": "Pick the ad", "why": "", "todo": "", "raised": Self.now - 120,
                                  "by": "manager", "options": options, "pictures": files]
        return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(
            withJSONObject: row.merging(extra) { _, new in new }))
    }

    /// The hub's word repairs itself at each read: a build that draws pictures and does not say so on its read of the
    /// state never gets an item with pictures (the feature never opens in his fleet).
    @Test func eachStateReadSaysExactlyWhatThisBuildDraws() async throws {
        for present in [false, true] {
            let hub = try OneAnswer(status: "200 OK") { _ in "{}" }
            _ = try? await HubClient(reads: HubReads()).stateReading(at: URL(string: "http://127.0.0.1:\(hub.port)/")!,
                                                                     present: present)
            let message = String(decoding: hub.received, as: UTF8.self)
            let head = message[..<(message.range(of: "\r\n\r\n")?.lowerBound ?? message.endIndex)]
            let said = head.split(separator: "\r\n").compactMap { line -> Set<String>? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == AppDraws.header.lowercased() else { return nil }
                return Set(parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            #expect(said == [[AppDraws.needPictures]], "present: \(present)")
        }
        #expect(AppDraws.names == [AppDraws.needPictures], "a name is said only once the card draws it")
    }

    /// **A picture over another option's words is a wrong choice made blind**: three options with two pictures, a file
    /// that is no picture, a request for a key, or a hub that does not name the feature, draw the card of before, and an
    /// item with no pictures keeps its rule of two options at least. One option with its picture is a choice (one
    /// design to approve).
    @Test func aPictureForEachOptionOrTheCardOfBefore() throws {
        let features = [AppDraws.needPictures]
        let three = try need(options: ["Dark", "Orange", "Blue"], pictures: [11, 12, 13])
        #expect(three.optionPictures(features: features)?.map(\.id) == [11, 12, 13])
        #expect(three.optionPictures(features: []) == nil)
        #expect(three.optionPictures(features: nil) == nil)
        #expect(try need(options: ["Dark", "Orange", "Blue"], pictures: [11, 12]).optionPictures(features: features) == nil)
        #expect(try need(options: ["Dark", "Orange"], pictures: [11, 12, 13]).optionPictures(features: features) == nil)
        #expect(try need(options: ["Dark", "Orange"], pictures: [11, 12], mime: "application/pdf")
            .optionPictures(features: features) == nil)
        #expect(try need(options: ["Dark", "Orange"], pictures: [11, 12], extra: ["kind": "secret"])
            .optionPictures(features: features) == nil)
        let one = try need(options: ["The new logo"], pictures: [21])
        #expect(one.choices == ["The new logo"] && one.optionPictures(features: features)?.map(\.id) == [21])
        #expect(try need(options: ["The new logo"], pictures: nil).choices.isEmpty)
        #expect(try need(options: ["The new logo"], pictures: nil).optionPictures(features: features) == nil)
    }
}
