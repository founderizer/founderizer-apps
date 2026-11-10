import SwiftUI

/// **View › Bigger, Smaller and Actual Size** (the owner's yes of 28 October 2026, D-8, as Grok Bot zooms with ⌘): the
/// whole window larger in steps of 115 %, up to 150 %, and back, kept on this Mac between launches. macOS has no
/// Dynamic Type, and the app's text runs from 10.5 to 14 points.
///
/// It is the window drawn larger, not a second set of sizes: the page is laid out in the window's size divided by the
/// zoom and drawn at the zoom (`ViewZoomed`), so every measure of the app — its type, its rows, its 1,100-point column —
/// grows together and nothing is laid out at a size no page was made for. The page never lays itself out in less than
/// the window's own least size, 960 × 560: in a smaller window the zoom goes only as far as that leaves room for.
enum ViewZoom {
    /// The zoom, kept on this Mac (`UserDefaults`).
    static let key = "viewZoom"
    /// 100 %, 115 %, 132 % and 150 %: each step 115 % of the one before, the last one held at 150 %.
    static let steps: [Double] = [1, 1.15, 1.3225, 1.5]
    /// The least size a page lays itself out in: the window's own minimum.
    static let least = CGSize(width: 960, height: 560)

    static func bigger(_ zoom: Double) -> Double { steps.first { $0 > zoom + 0.001 } ?? steps[steps.count - 1] }
    static func smaller(_ zoom: Double) -> Double { steps.last { $0 < zoom - 0.001 } ?? steps[0] }

    /// The zoom a window of `size` can take: the one he chose, as far as the page keeps its least size, and never
    /// less than 100 %.
    static func shown(_ zoom: Double, in size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(1, min(CGFloat(zoom), size.width / least.width, size.height / least.height))
    }
}

/// The three items of the View menu, under Refresh Founderizer. Each one shows only what it can do: Bigger stops at
/// 150 %, and Smaller and Actual Size at 100 %.
struct ViewZoomCommands: Commands {
    @AppStorage(ViewZoom.key) private var zoom = 1.0
    /// The size of the window in front (`zoomRoom`).
    @FocusedValue(\.zoomRoom) private var room

    /// **Bigger is dimmed while the window in front cannot take the next step** (fix round 2), as macOS dims a menu
    /// item that would do nothing: in a 960-point window the page keeps its least size, so Bigger changed nothing.
    private var biggerShows: Bool {
        guard zoom < ViewZoom.steps[ViewZoom.steps.count - 1] - 0.001 else { return false }
        guard let room else { return true }
        return ViewZoom.shown(ViewZoom.bigger(zoom), in: room) > ViewZoom.shown(zoom, in: room) + 0.001
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger") { zoom = ViewZoom.bigger(zoom) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!biggerShows)
            Button("Smaller") { zoom = ViewZoom.smaller(zoom) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.001)
            Button("Actual Size") { zoom = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom <= 1.001)
        }
    }
}

extension EnvironmentValues {
    /// The zoom the window is drawn at, for the few views that measure the pointer in the window's own points (the
    /// edge he drags to widen a side menu, `SideEdge`), and for a window of its own that opens from it (`zoomedAsItsWindow`).
    @Entry var viewZoom: CGFloat = 1
}

extension FocusedValues {
    /// The size of the zoomed window in front, for View › Bigger (`ViewZoomCommands`).
    @Entry var zoomRoom: CGSize?
}

extension View {
    /// The window's content at the zoom he chose (View › Bigger …): the root of the app's window, and the card over it,
    /// which is a window of its own (`fleetModal`). Both run to their window's top edge, so it takes the whole window,
    /// the room under the traffic lights included, as the window's own content does.
    func viewZoomed() -> some View { modifier(ViewZoomed()) }

    /// **A window of its own that opens from the zoomed window takes that window's zoom** (fix round 2): the list of a
    /// select and the agent's "…" menu (`FleetSelect`), which stand in a popover, kept 100 % — 13-point rows under a
    /// trigger drawn at 150 %. Laid out at its own size and drawn at the zoom, with the room the zoom takes.
    func zoomedAsItsWindow() -> some View { modifier(ZoomedAsItsWindow()) }
}

private struct ZoomedAsItsWindow: ViewModifier {
    @Environment(\.viewZoom) private var zoom

    func body(content: Content) -> some View {
        ZoomedSize(zoom: zoom) { content }.scaleEffect(zoom, anchor: .topLeading)
    }
}

/// Lays its one subview out at its own size and takes that size times the zoom, for `scaleEffect` to draw it in.
private struct ZoomedSize: Layout {
    let zoom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let inner = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / zoom },
                                                        height: proposal.height.map { $0 / zoom }))
        return CGSize(width: inner.width * zoom, height: inner.height * zoom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width / zoom, height: bounds.height / zoom))
    }
}

/// Lays the content out in the window's size divided by the zoom and draws it at the zoom, from the top left corner.
/// At 100 % it is the content as it is: the same views in the same place, so choosing a zoom never builds the window's
/// views again (a field that has the keyboard stays the same field).
struct ViewZoomed: ViewModifier {
    @AppStorage(ViewZoom.key) private var zoom = 1.0
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        let shown = ViewZoom.shown(zoom, in: size)
        ZoomLayout(zoom: shown) { content.environment(\.viewZoom, shown) }
            .scaleEffect(shown, anchor: .topLeading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .ignoresSafeArea(.container, edges: .top)
            .focusedSceneValue(\.zoomRoom, size)
    }
}

/// Gives its one subview the size it is given divided by the zoom, at its own top left corner; `scaleEffect` then
/// draws it back over the whole size.
private struct ZoomLayout: Layout {
    let zoom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let inner = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 / zoom },
                                                        height: proposal.height.map { $0 / zoom }))
        return CGSize(width: proposal.width ?? inner.width * zoom, height: proposal.height ?? inner.height * zoom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width / zoom, height: bounds.height / zoom))
    }
}
