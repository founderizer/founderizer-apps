import FleetCore
import SwiftUI

// **A component's literal title is looked up, as `Text`'s is** (`Localization/README.md`). `FormRow("Turn off")` takes
// these inits and shows the words of the device's language; `FormRow(name)` with a `String` value takes the
// component's own init, which is `@_disfavoredOverload`, and shows the value as it is. So the call sites need no change,
// and the compiler lists each literal title for `Localization/l10n.py check`. Other `String` parameters (`detail:`,
// `footer:`) take `String(l10n:)` at the call site.

extension FormSection {
    init(_ title: String.LocalizationValue, detail: String? = nil, footer: String? = nil, lazy: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.init(String(l10n: title) as String?, detail: detail, footer: footer, lazy: lazy, content: content, accessory: accessory)
    }
}

extension FormSection where Accessory == EmptyView {
    init(_ title: String.LocalizationValue, detail: String? = nil, footer: String? = nil, lazy: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(String(l10n: title) as String?, detail: detail, footer: footer, lazy: lazy, content: content)
    }
}

extension FormRow {
    init(_ title: String.LocalizationValue, symbol: String? = nil, detail: String? = nil, warning: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.init(String(l10n: title), symbol: symbol, detail: detail, warning: warning, control: control)
    }

    init(_ title: String.LocalizationValue, mark: some View, detail: String? = nil, warning: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.init(String(l10n: title), mark: mark, detail: detail, warning: warning, control: control)
    }
}

extension FormRow where Control == EmptyView {
    init(_ title: String.LocalizationValue, symbol: String? = nil, detail: String? = nil, warning: String? = nil) {
        self.init(String(l10n: title), symbol: symbol, detail: detail, warning: warning)
    }

    init(_ title: String.LocalizationValue, mark: some View, detail: String? = nil, warning: String? = nil) {
        self.init(String(l10n: title), mark: mark, detail: detail, warning: warning)
    }
}

extension FleetSegmented {
    init(_ title: String.LocalizationValue, selection: Binding<Value>, options: [FleetOption<Value>]) {
        self.init(String(l10n: title), selection: selection, options: options)
    }
}

extension FormBlock {
    init(_ title: String.LocalizationValue, detail: String? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.init(String(l10n: title), detail: detail, content: content, accessory: accessory)
    }
}

extension FormBlock where Accessory == EmptyView {
    init(_ title: String.LocalizationValue, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(String(l10n: title), detail: detail, content: content)
    }
}

extension FormEmpty {
    init(_ text: String.LocalizationValue, symbol: String, draws: Bool = false, @ViewBuilder action: () -> Action) {
        self.init(String(l10n: text), symbol: symbol, draws: draws, action: action)
    }
}

extension FormEmpty where Action == EmptyView {
    init(_ text: String.LocalizationValue, symbol: String, draws: Bool = false) {
        self.init(String(l10n: text), symbol: symbol, draws: draws)
    }
}

extension PageHeader {
    init(_ title: String.LocalizationValue, mark: AnyView? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(String(l10n: title), mark: mark, actions: actions)
    }
}

extension PageHeader where Actions == EmptyView {
    init(_ title: String.LocalizationValue) { self.init(String(l10n: title)) }
}

extension FleetBack {
    init(_ title: String.LocalizationValue, action: @escaping () -> Void) { self.init(String(l10n: title), action: action) }
}

extension FleetPage {
    init(_ title: String.LocalizationValue, back: FleetBack? = nil, mark: AnyView? = nil, fills: Bool = false,
         board: Bool = false, wide: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(String(l10n: title), back: back, mark: mark, fills: fills, board: board, wide: wide, content: content,
                  actions: actions)
    }
}

extension FleetPage where Actions == EmptyView {
    init(_ title: String.LocalizationValue, back: FleetBack? = nil, fills: Bool = false, board: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.init(String(l10n: title), back: back, fills: fills, board: board, content: content)
    }
}

extension FleetOption {
    init(_ value: Value, _ title: String.LocalizationValue, subtitle: String? = nil, detail: String? = nil,
         mark: FleetSelectMark = .none, section: String? = nil, destructive: Bool = false) {
        self.init(value, String(l10n: title), subtitle: subtitle, detail: detail, mark: mark, section: section,
                  destructive: destructive)
    }
}

extension FleetSelect {
    init(_ title: String.LocalizationValue, options: [FleetOption<Value>], selection: Value? = nil,
         onSelect: @escaping (Value) -> Void, @ViewBuilder label: () -> Label) {
        self.init(String(l10n: title), options: options, selection: selection, onSelect: onSelect, label: label)
    }
}

extension FleetSelect where Label == FleetSelectLabel {
    init(_ title: String.LocalizationValue, selection: Binding<Value>, options: [FleetOption<Value>], placeholder: String? = nil) {
        self.init(String(l10n: title), selection: selection, options: options, placeholder: placeholder ?? String(l10n: "Choose"))
    }
}
