import AppKit
import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **Each card takes the short names of its own Give, and of no other card's** (the owner, 23 November 2026: "Yes: a
/// name that the card's Give names is a badge"), from the books that the app keeps (`FleetStore.cardNames(for:)`),
/// which every place of a card's words asks.
@Suite(.serialized, .timeLimit(.minutes(1))) struct CardGiveNamesTests {
    /// A request of the manager's whose Give names `repos`; none: a request with no Give.
    private static func need(_ id: Int, why: String = "It pushes the new page.",
                             gives repos: [String]) -> [String: Any] {
        let give: [String: Any] = ["agent": "nova", "level": "write", "repos": repos]
        return ["id": id, "title": "Let Nova write", "raised": Int(Date().timeIntervalSince1970) - 300, "by": "manager",
                "todo": "", "why": why, "answered": NSNull(), "give": repos.isEmpty ? NSNull() as Any : give]
    }

    /// The bugs that this catches: the card takes the one book, so its repository's name stays words; a kept book of
    /// another card's Give, so a word of this card opens a repository that it does not give; or a kept book after the
    /// names changed (a cache that ignores its key), so a repository that a new request gives stays words.
    @Test func eachCardTakesTheNamesOfItsOwnGiveAndNoOther() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> [[String]] in
            let needs = [Self.need(91, gives: ["acme/web"]), Self.need(92, gives: ["acme/docs"]),
                         Self.need(93, gives: [])]
            let store = ViewHost.store(try ViewHost.reading(needs: needs, features: []))
            let text = "Push it to web and docs, then shop-api."
            @MainActor func read() -> [[String]] {
                [91, 92, 93].map { id in
                    guard let need = store.state?.needs.first(where: { $0.id == id }) else { return ["no card"] }
                    return store.cardNames(for: need).find(in: text).map { String(text[$0.range]) }
                }
            }
            // twice: the second time each book is a kept one; then a new request gives acme/shop-api, whose name
            // has a hyphen, so every card's book holds it
            let first = read(), kept = read()
            store.state = try ViewHost.reading(needs: needs + [Self.need(94, gives: ["acme/shop-api"])], features: [])
            return first + kept + read()
        }
        #expect(seen == [["web"], ["docs"], [], ["web"], ["docs"], [],
                         ["web", "shop-api"], ["docs", "shop-api"], ["shop-api"]])
        #expect(screen.stayedHis)
    }

    /// **The card in the manager's chat draws its Give's short name as a badge.** The bug that this catches: the card's
    /// view takes the one book again, with no Give, and "web" stays words.
    @Test func theCardInAChatDrawsTheShortNameOfItsGiveAsABadge() async throws {
        let (presses, screen) = try await ViewHost.onMainLoop { () -> Int in
            let store = ViewHost.store(try ViewHost.reading(
                needs: [Self.need(95, why: "It pushes the new page to web today.", gives: ["acme/web"])],
                features: []))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "pushes", in: window) != nil else {
                throw ViewHost.Missing(description: "the card does not show its words")
            }
            @MainActor func presses(_ view: NSView) -> Int {
                (view is BadgePress.PressView ? 1 : 0) + view.subviews.map(presses).reduce(0, +)
            }
            ViewHost.turn(10) { presses(window.contentView!) > 0 }
            return presses(window.contentView!)
        }
        #expect(presses == 1, "one badge: web")
        #expect(screen.stayedHis)
    }
}
