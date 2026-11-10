/// **Back and forward between pages, as a browser keeps them** (the owner, 3 November 2026: "there should be 2 buttons
/// to go back and forth between pages while navigating the app, like in codex"). Each page he leaves goes on the back
/// list; a step back puts the page he leaves on the forward list, and a page he opens himself ends the forward list.
/// A page that cannot open any more (an agent the hub no longer lists) is passed over.
public struct PageHistory<Page: Equatable>: Equatable {
    public private(set) var back: [Page] = []
    public private(set) var forward: [Page] = []

    /// The most pages either list keeps: the oldest goes first.
    public static var limit: Int { 50 }

    public init() {}

    /// He opened `next` himself, from `page`.
    public mutating func went(from page: Page, to next: Page) {
        guard page != next else { return }
        back.append(page)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// Every page of both lists through `change`: a page that took a new name (a server renamed) keeps its place.
    public mutating func rename(_ change: (Page) -> Page) {
        back = back.map(change)
        forward = forward.map(change)
    }

    /// The page one step back from `page`, the newest one that can open, or nil.
    public mutating func goBack(from page: Page, canOpen: (Page) -> Bool = { _ in true }) -> Page? {
        while let previous = back.popLast() {
            guard canOpen(previous), previous != page else { continue }
            forward.append(page)
            if forward.count > Self.limit { forward.removeFirst(forward.count - Self.limit) }
            return previous
        }
        return nil
    }

    /// The page one step forward from `page`, the newest one that can open, or nil.
    public mutating func goForward(from page: Page, canOpen: (Page) -> Bool = { _ in true }) -> Page? {
        while let next = forward.popLast() {
            guard canOpen(next), next != page else { continue }
            back.append(page)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
            return next
        }
        return nil
    }
}
