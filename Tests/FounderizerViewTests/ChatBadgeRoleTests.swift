import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **The role beside a name in a chat's badge is grey and no part of the name's link** (`ChatBadgeText.drawn`; the
/// owner's answer of 23 November 2026: "The name with the role in grey"), as in a card's badge: one link for one name,
/// for the keyboard and VoiceOver (a run with its own colour keeps it with or without a link, as measured on 24 November
/// 2026). The words stay "Atlas · Marketing". The bug that this catches: the role keeps the name's link (a second link
/// of one name), the role draws in the words' colour, or the name loses its link.
@MainActor @Test func theRoleInAChatsBadgeIsGreyAndNoPartOfTheNamesLink() throws {
    let words = ChatNames(agents: [("atlas", "Marketing")]).words(AttributedString("I asked Marketing."))
    let drawn = ChatBadgeText.drawn(words.text)
    #expect(drawn.runs[\.link].compactMap { $0.0 == nil ? nil : String(drawn[$0.1].characters) } == ["Atlas"])
    #expect(String(drawn.characters) == "I asked Atlas · Marketing.")
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
    #expect(grey > 200, "the role's part draws grey: \(grey) grey pixels")
}
