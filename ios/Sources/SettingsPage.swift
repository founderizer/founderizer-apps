import FleetCore
import SwiftUI

/// Settings: the hub address, this phone's own key for the hub, and the request that waits for its receipt, with
/// Try again and Discard; under them, the credit. The ping switches come with the pings (MOBILE-APP.md 13, phase 3).
///
/// It is a grouped form, as this platform's own settings are: one group for each thing and the facts in the rows.
/// **No group explains itself** (the owner's yes of 28 October 2026 to D-2: "avoid as much text as possible
/// everywhere!!"): a footer carries only what went wrong, and what the hub refused stands once, in the line over the
/// page. The page had 97 words.
struct SettingsPage: View {
    @Bindable var store: MobileStore
    /// The address's size, which stops at the second accessibility size's 33 points (fix round 3, HIG): the field
    /// ignored the size limit and broke the address inside its port at AX5.
    @ScaledMetric(relativeTo: .body) private var addressSize: CGFloat = 17
    @State private var forgetError: (words: String, detail: String)?

    var body: some View {
        Form {
            Section {
                // It wraps, so the whole address reads at every text size: it was cut to "http://127.0.0…". Its
                // placeholder and its name are the Mac's example address (review B9i): they were the owner's own hub.
                TextField(text: $store.addressText,
                          prompt: Text(verbatim: "http://100.84.1.2:8765").foregroundStyle(Brand.placeholder),
                          axis: .vertical) {
                    Text(verbatim: "http://100.84.1.2:8765")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // **The address breaks only after "//"** (fix round 2, item 56): its host and port are one word to the
                // line breaker, and at the largest text sizes it broke inside the port ("634" / "04"). Up to the second
                // accessibility size the host and port fit one line under "http://".
                .font(.system(size: min(addressSize, 33)))
                Button("Connect") { Task { await store.connect() } }
            } header: {
                GroupHeading("Hub")
            } footer: {
                if let error = store.addressError { Text(error).foregroundStyle(Brand.warning) }
            }
            .brandRows()

            // **"Last read" only while the reading is not current**: a row that says "just now" in green says only
            // that nothing is wrong. Current as the marks are (fix round 3d, D-1 rule 2): not in a read's first second.
            // None on a phone with no hub: there is no reading to be old.
            if !store.showsCurrent && !store.hasNoHub {
                Section {
                    LabeledContent("Last reading") {
                        Text(store.lastRead.map { fleetAge($0.timeIntervalSince1970,
                                                           now: Date().timeIntervalSince1970) } ?? "Never")
                            .foregroundStyle(Brand.warning)
                    }
                    .wholePoints()
                }
                .brandRows()
            }

            keySection

            pendingSection

            // **The credit, one muted line under the last group** (the owner's yes of 10 November 2026 to its
            // picture: "Yes, add them"): who made Founderizer, and his handle, the link to his profile on X
            // (`Credit`, which the Mac's About window shows too). It stands on the page with no card: it is no setting.
            Section {
                Text(Credit.oneLine)
                    .font(.footnote).foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .wholePoints()
                    .accessibilityIdentifier("credit")
            }
            .brandRows(cards: false)
        }
        .brandPage()
        .task { await store.readDevice() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .hubBanner(store, settings: false)
    }

    /// This phone's key: whether it has one and where it stands. The key itself never shows, here or anywhere else.
    private var keySection: some View {
        Section {
            LabeledContent("Device key") { Text(keyValue).foregroundStyle(keyColor) }
                .wholePoints()
                // The keychain's own words, when it gave some, for VoiceOver; the screen says it in its own.
                .accessibilityHint(store.keyDetail ?? "")
            // No Unlock on a phone with no hub, or in the sample fleet: there is no hub to reach with the key.
            if !store.hasNoHub && !store.sample && (store.keyState == .locked || store.keyWords != nil) {
                // The read follows the unlock: with the key in hand the hub answers, so the page stops saying that
                // it does not.
                Button("Unlock") { Task { await store.unlock(); await store.refresh() } }
            }
            if let device = store.device {
                // Its name for what the row holds (fix round 2, item 42): "The hub calls this phone" read as an action.
                DetailRow(title: "This phone's address", detail: "\(device.label) · \(device.address)",
                          value: device.last_seen.map { fleetAge($0, now: store.hubNow) } ?? "No read yet")
            }
            NavigationLink("Add this phone", value: ChatsRoute.enroll)
                .accessibilityIdentifier("open-enroll")
            if store.deviceKey.has {
                Button("Forget the key", role: .destructive) { forgetError = store.forgetKey() }
                    .accessibilityIdentifier("forget-key")
            }
        } header: {
            GroupHeading("This phone")
        } footer: {
            if let forgetError {
                Text(forgetError.words).foregroundStyle(Brand.warning).accessibilityValue(forgetError.detail)
            }
        }
        .brandRows()
    }

    private var keyValue: String {
        switch store.keyState {
        case .none: "None"
        case .locked: "Locked"
        case .ready: "In hand"
        case .failed: "Not given"
        }
    }

    private var keyColor: Color {
        switch store.keyState {
        case .ready: Brand.online
        case .none: Brand.muted
        case .locked, .failed: Brand.warning
        }
    }

    /// The one request that may wait, as the phone holds it: what it is, where it stands, and **the one action that
    /// fits** (T-35): Try again while it waits for its receipt, Discard when the hub refused it. Nothing here makes a
    /// new number: Try again sends the same request again. Its number does not show: it is the hub's, not his, and
    /// a read finds the request's event by itself, so "Read the hub" was a second action for one failure.
    @ViewBuilder private var pendingSection: some View {
        if let storageError = store.storageError {
            Section {
                DetailRow(title: "Sending is blocked", detail: storageError, value: "Blocked", valueColor: Brand.warning)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(store.storageErrorDetail ?? "")
            } header: {
                GroupHeading("Pending write")
            }
            .brandRows()
        } else if let pending = store.pending {
            Section {
                DetailRow(title: store.pendingSummary,
                          detail: pending.refusal ?? store.sendError ?? "It waits for its receipt.",
                          value: pending.refusal == nil ? "Waiting" : "Refused", valueColor: Brand.warning)
                if !pending.text.isEmpty {
                    Text(verbatim: pending.text).font(.footnote).foregroundStyle(Brand.muted)
                        .lineLimit(4).textSelection(.enabled)
                }
                // **Each action only while it can act, never grey** (review B2i), as the Mac's pending bar: Discard
                // for a refused write, which nothing sends any more; Try again while the hub can take it.
                if pending.refusal != nil {
                    Button("Discard", role: .destructive) { store.discardRefused() }
                        .accessibilityIdentifier("discard-pending")
                } else if store.canRetry {
                    Button("Try again") { Task { await store.retry() } }
                        .accessibilityIdentifier("retry-pending")
                }
            } header: {
                GroupHeading("Pending write")
            } footer: {
                // Only what is known: the hub address is this app's own, but the generation needs a read.
                if pending.hub != store.hub || store.snapshot.map({ $0.db != pending.database }) == true {
                    Text("It belongs to another hub, so it is not sent again.")
                        .foregroundStyle(Brand.warning)
                }
            }
            .brandRows()
        }
        // Nothing waits: no section at all. A card that says only that nothing is wrong is a card he reads
        // every time and acts on never, and the page is shorter without it.
    }
}
