import Foundation

/// The words of the apps in the language of the device (`app/Localization/`, its README says how a word gets in).
///
/// The key of a word is its English text. A build carries a language's table only when `Localization/shipped` names
/// it, so with no table every lookup gives the English text, character for character.
///
/// Only words that the apps write themselves go through a lookup. A value that goes to the hub, that the app compares
/// with the hub's text or that it signs stays English, and an agent's or the hub's own text is shown as it is.
public enum Localized {
    /// Where the words come from: the app's own bundle. A test gives one language's `.lproj` bundle to its own task
    /// (`Localized.$bundle.withValue(...)`), so tests that run beside it keep the English words.
    @TaskLocal public static var bundle: Bundle = .main

    /// A whole number keeps its plain digits in every language, as the English text had them before the lookups:
    /// with the current locale, 1234 came out as "1.234" on a Mac with the region Spain. Public for a key of its own
    /// (`String(localized: "Off (a server)", defaultValue: "Off", bundle: Localized.bundle, locale: Localized.digits)`).
    public static let digits = Locale(identifier: "en_US_POSIX")
}

extension String {
    /// A word or a sentence that the app shows, in the language of the device: `String(l10n: "Sent to \(app)")`.
    ///
    /// The compiler lists its key (`Sent to %@`) for `Localization/l10n.py check`. Make a `Double` a `String` before
    /// it goes in: in a lookup it would be written as "1.500000".
    public init(l10n value: String.LocalizationValue) {
        self.init(localized: value, bundle: Localized.bundle, locale: Localized.digits)
    }
}
