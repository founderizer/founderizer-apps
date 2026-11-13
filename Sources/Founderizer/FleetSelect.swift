import AppKit
import FleetCore
import SwiftUI

// The app's dropdown, in place of the macOS pop-up menus: a capsule that opens its list in the app's menu (`FleetMenu`)
// under it. A row has a mark, a title, an optional muted line and a check mark on the selection. The pointer and the
// arrow keys move the highlight, a click or Return chooses, Esc closes, and typing filters a list of more than eight
// rows. See UI-PATTERNS.md.

/// The mark at the leading edge of a row and of the trigger.
enum FleetSelectMark {
    case none
    /// An SF Symbol, for a list of things that are not agents or providers.
    case symbol(String)
    /// An agent: its glyph, and its status dot when the presence is known.
    case agent(String, AgentPresence?)
    /// A provider or a provider account: the provider's icon.
    case provider(String)
    /// A chat app: its own mark, never a speech bubble.
    case chatApp(String)
    /// A right-click item's own symbol, as SwiftUI made it for the system's menu (`FleetContextMenus`).
    case image(NSImage)

    /// An agent with its status from the hub's last reading. An agent that the hub does not list has no dot.
    static func agent(_ name: String, state: HubState?, isFresh: Bool) -> FleetSelectMark {
        guard let state, let agent = state.agents.first(where: { $0.name == name }) else { return .agent(name, nil) }
        let open = state.tasks.filter { $0.owner == name && !$0.isTerminal }
        return .agent(name, agent.presence(isFresh: isFresh, serverTime: state.time, openTasks: open, holds: state.holds ?? []))
    }

    var presence: AgentPresence? { if case .agent(_, let presence) = self { presence } else { nil } }
    var isNone: Bool { if case .none = self { true } else { false } }
}

/// One row of a `FleetSelect`.
struct FleetOption<Value: Hashable> {
    let value: Value
    let title: String
    /// One muted line under the title, in the list only.
    var subtitle: String?
    /// A short muted word after the title, in the list and in the trigger: an ID or a count.
    var detail: String?
    var mark: FleetSelectMark
    /// The heading of the row's group. A heading shows where it changes, so the rows of a group are next to each other.
    var section: String?
    /// An action that deletes: its words and its mark in red.
    var destructive: Bool

    @_disfavoredOverload
    init(_ value: Value, _ title: String, subtitle: String? = nil, detail: String? = nil, mark: FleetSelectMark = .none,
         section: String? = nil, destructive: Bool = false) {
        self.value = value; self.title = title; self.subtitle = subtitle; self.detail = detail; self.mark = mark; self.section = section
        self.destructive = destructive
    }
}

/// A dropdown. With a selection binding, the trigger is a secondary capsule with the selected row's mark, title and
/// detail; a value that no row has shows the placeholder. With a label of its own, it is a menu: the button style
/// around it draws the trigger, and a chosen row goes to `onSelect`.
struct FleetSelect<Value: Hashable, Label: View>: View {
    private let title: String
    private let options: [FleetOption<Value>]
    private let selection: Value?
    private let onSelect: (Value) -> Void
    private let label: Label
    /// The zoom of the window it stands in (View › Bigger), which its list takes: the list is a window of its own.
    @Environment(\.viewZoom) private var zoom
    /// The control's own view, for the place of its list.
    @State private var anchor = FleetMenuAnchor.Spot()

    /// A menu behind the caller's label. The row of `selection`, when there is one, has the check mark.
    @_disfavoredOverload
    init(_ title: String, options: [FleetOption<Value>], selection: Value? = nil, onSelect: @escaping (Value) -> Void,
         @ViewBuilder label: () -> Label) {
        self.title = title; self.options = options; self.selection = selection; self.onSelect = onSelect; self.label = label()
    }

    var body: some View {
        // A click on the control of an open list closes the list and goes no further (`FleetMenu`), so it never opens
        // the list again.
        let button = Button { open() } label: { label }
        // The newest action alone: a closure that took this view with it would keep its anchor, and so itself.
        let onSelect = onSelect
        Group {
            if Label.self == FleetSelectLabel.self { button.buttonStyle(FleetOutlineButtonStyle()) } else { button }
        }
        .background(FleetMenuAnchor(spot: anchor) { value in if let value = value.base as? Value { onSelect(value) } })
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }

    /// The list under the control, its selection highlighted; a menu of actions opens with no row highlighted, as a
    /// macOS menu does.
    private func open() {
        guard let view = anchor.view, let window = view.window else { return }
        let items = options.map { option in
            FleetMenuItem(title: option.title, subtitle: option.subtitle, detail: option.detail, mark: option.mark,
                          checked: selection != nil && option.value == selection, destructive: option.destructive,
                          section: option.section)
        }
        // The row he chose, as the list showed it, to the page's newest action (`FleetMenuAnchor.Spot`).
        let values = options.map(\.value)
        let spot = anchor
        FleetMenu.show(items, highlighted: options.firstIndex { selection != nil && $0.value == selection },
                       filters: options.count > 8, at: .under(window.convertToScreen(view.convert(view.bounds, to: nil))),
                       over: window, zoom: zoom, owner: view) { index in spot.select?(AnyHashable(values[index])) }
    }
}

extension FleetSelect where Label == FleetSelectLabel {
    /// A dropdown for one value. A value that no row has shows the placeholder in the muted color.
    @_disfavoredOverload
    init(_ title: String, selection: Binding<Value>, options: [FleetOption<Value>], placeholder: String = String(l10n: "Choose")) {
        let current = options.first { $0.value == selection.wrappedValue }
        self.init(title, options: options, selection: selection.wrappedValue, onSelect: { selection.wrappedValue = $0 }) {
            FleetSelectLabel(title: current?.title ?? placeholder, detail: current?.detail, mark: current?.mark ?? .none,
                             placeholder: current == nil)
        }
    }
}

/// The trigger of a selection: the mark (an agent's with its status dot on its corner), the title, the detail and a
/// chevron. The button style draws the capsule.
struct FleetSelectLabel: View {
    let title: String
    var detail: String?
    var mark: FleetSelectMark = .none
    /// The placeholder shows in the muted color.
    var placeholder = false

    var body: some View {
        HStack(spacing: 7) {
            FleetSelectMarkView(mark: mark, size: 15)
            Text(title).lineLimit(1)
                .foregroundStyle(placeholder ? AnyShapeStyle(FleetStyle.muted) : AnyShapeStyle(.foreground))
            if let detail { Text(detail).fontWeight(.regular).foregroundStyle(FleetStyle.muted).lineLimit(1) }
            Image(systemName: "chevron.down").font(IconMetrics.symbol(8.5, weight: .bold)).foregroundStyle(FleetStyle.muted)
                .padding(.leading, 1).accessibilityHidden(true)
        }
    }
}

/// The mark of a row or of the trigger. **An agent's status dot stands on its glyph's corner**, as everywhere else (the
/// owner's yes of 28 October 2026, D-8); it stood at the row's far end.
struct FleetSelectMarkView: View {
    let mark: FleetSelectMark
    let size: CGFloat

    var body: some View {
        switch mark {
        case .none: EmptyView()
        case .symbol(let name):
            Image(systemName: name).font(IconMetrics.symbol(size * 0.8)).foregroundStyle(FleetStyle.muted)
                .frame(width: size, height: size).accessibilityHidden(true)
        // An agent keeps the glyph's inline size in the trigger and in the list, as beside every other name.
        case .agent(let name, let presence):
            if let presence { AgentAvatar(name: name, presence: presence, size: GlyphSize.inline) }
            else { AgentGlyph(name: name, size: GlyphSize.inline) }
        case .provider(let runtime): ProviderIcon(runtime: runtime, size: size).accessibilityHidden(true)
        case .chatApp(let app):
            BrandMark(app: app, size: size * 0.82).foregroundStyle(BrandMark.color(app))
                .frame(width: size, height: size)
        case .image(let image):
            Image(nsImage: image).renderingMode(.template).foregroundStyle(FleetStyle.muted)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}
