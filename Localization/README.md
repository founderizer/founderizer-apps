# The apps' words in other languages

The Mac app and the iPhone app show their words in the language of the device. Spanish (`es`) is the first language.
The plan: `~/dev/founderizer-plans/app-localization-plan.md`.

## The files

- `Localizable.xcstrings`: the table, Apple's String Catalog (Xcode opens it). The key of each entry is the English
  text, with `%@` for a text value and `%lld` for a whole number. Spanish is neutral Spanish, with "tú".
- `shipped`: the languages that the builds carry, one code on each line. **A language goes in only after the owner's
  yes to the pictures of the pages in it.** Spanish since 14 November 2026 (his "Yes, as shown").
- **How each build carries the table:** the Mac app's `run.sh` and `release.sh` run `l10n.py compile` into the app's
  `Contents/Resources` (the languages of `shipped`, and `en`). The iPhone project has the catalog itself as a resource
  of the app and of the Share extension, so Xcode compiles it into both (proved with `xcodebuild` on 14 November 2026:
  the build does not write into the catalog). Xcode takes every language of the catalog, whatever `knownRegions` says,
  so **the table holds words only in the languages of `shipped`**; `check` fails on any other language. The notification
  extensions have no words of their own and no table.
- `l10n.py`: `keys` lists the compiler's keys, `sync` adds new keys to the table and removes keys that no code uses,
  `check` finds the faults, `compile` puts the shipped tables into an app (`run.sh`, `release.sh`). Each of the first
  three builds the Mac app in `.build/l10n` first; `--ios` also builds the iPhone app.

## How a word gets in

1. Write the word in a way that the compiler sees:
   - a literal in `Text`, `Button`, `Label`, `Toggle`, `Section`, `TextField` and the other SwiftUI views;
   - a literal title of the app's own components (`FormRow("Turn off")`, `FormSection`, `FormEmpty`, `FleetPage`,
     `FleetOption` and the others in `Sources/Founderizer/LocalizedTitles.swift`);
   - `String(l10n: "Sent to \(app)")` for text that the code builds (`Sources/FleetCore/Localized.swift`).
2. Run `python3 Localization/l10n.py sync`.
3. Write the Spanish in the table, with the same values (`%@`, `%lld`) in the same order, or by position (`%2$@ %1$@`).
4. `python3 Localization/l10n.py check` lists what is missing or wrong.

## Rules

- **The English stays the same, character for character.** A whole number keeps its plain digits. A `Double` is made a
  `String` before it goes into `String(l10n:)`; the check refuses a key with `%f`.
- **A `String` shown with `Text(value)` is shown as it is.** So a word that the code keeps in a `String` must come from
  `String(l10n:)` where it is made.
- **Only the apps' own words.** An agent's text, the hub's text and every value that goes to the hub, that the app
  compares or that it signs stay as they are. Example: the door card's title and answers (`DoorCall`) are compared
  with the hub's card in English. **One exception: the words of a refusal whose code the app knows** (the owner's
  "Yes, as shown" of 16 November 2026; UI-API.md 1.181). `Sources/FleetCore/RefusalWords.swift` has one case for each
  code of `vectors/refusal-codes.json`, and the key of each is the hub's English, with `%@` where the hub has a
  `{name}` (a name stays as the hub wrote it). On a device in English, for a code that the table does not have, for a
  refusal that lacks a name and for a key with no words in the language, the hub's own line shows, so the English is
  the hub's character for character. A new code of the hub gets its case and its Spanish in the same commit, and the
  owner's yes to the words of its slice comes first; until then its name is in `RefusalWordsVectorsTests.waiting`. A
  line that decides something never reads these words: it reads `HubRefusal.means(_:)`, which reads the code.
- A name of a product or a service ("GitHub", "Tailscale") has an entry with the same words in Spanish.
- **A word with two meanings gets a key of its own for one of them**, with its English apart, so the English stays the
  same: `String(localized: "Off (a server)", defaultValue: "Off", bundle: Localized.bundle, locale: Localized.digits)`
  in FleetCore. "Off" stays the switch's word ("Desactivado"); "Off (a server)" is a server that is powered off
  ("Apagado").
