import CoreImage
import CoreImage.CIFilterBuiltins
import FleetCore
import SwiftUI

// The small views that the Channels pages, Settings and the agent chat share: the brand marks, the status line, a QR
// code, the owner's link step, and the delivery icons under a reply.

/// The WhatsApp or the Discord mark: the SVG path data of Simple Icons 16.34.0 (CC0, published 4 October 2026, read
/// from the npm package), drawn by AppKit as a template image, so that it takes the color that the caller gives: the
/// brand color on a card, white or gray in a small place. The app bundles no image file and reads no network.
struct BrandMark: View {
    let app: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.image(app)).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size).accessibilityHidden(true)
    }

    /// The brand color of a card's mark: WhatsApp #25D366, Discord #5865F2.
    static func color(_ app: String) -> Color {
        switch app {
        case "whatsapp": Color(red: 0x25 / 255, green: 0xD3 / 255, blue: 0x66 / 255)
        case "discord": Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)
        default: FleetStyle.text
        }
    }

    @MainActor private static func image(_ app: String) -> NSImage {
        switch app {
        case "whatsapp": whatsApp
        case "discord": discord
        default: NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil) ?? NSImage()
        }
    }

    // simple-icons@16.34.0 icons/whatsapp.svg (SHA-256 8fb209a5…) and icons/discord.svg (SHA-256 1d364b72…).
    @MainActor private static let whatsApp = image(path: "M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z")
    @MainActor private static let discord = image(path: "M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z")

    private static func image(path: String) -> NSImage {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d=""#
            + ChatApps.spacedPath(path) + #""/></svg>"#
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// The mark of a channel in a small place (the corner of a chat bubble): the brand mark in white in a small round
/// tile. The app's name is the hover text and the label.
struct ChatAppMark: View {
    let app: String
    var size: CGFloat = 18
    var help: String?

    var body: some View {
        BrandMark(app: app, size: size * 0.58).foregroundStyle(FleetStyle.text)
            .frame(width: size, height: size)
            .background(FleetStyle.surface, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .help(help ?? ChatApps.title(app))
            .accessibilityElement().accessibilityLabel(help ?? ChatApps.title(app))
    }
}

/// The mark of a status: a green dot, an orange dot, or a gray ring while it waits, is old, is off or has nothing yet.
struct ToneDot: View {
    let tone: ChatTone

    var body: some View {
        Group {
            switch tone {
            case .good: Circle().fill(Color.green)
            case .problem: Circle().fill(Color.orange)
            case .waiting, .off: Circle().strokeBorder(FleetStyle.muted, lineWidth: 1.2)
            }
        }.frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A status: a dot (or a small spinner) and one or two words. The longer reason and an old reading's time are the
/// hover text.
struct ChannelStatusLine: View {
    let status: ChatStateWords
    var spinning = false

    var body: some View {
        let hover = [status.detail, status.readingAt.map { "Last reading \(messageTime($0))." }].compactMap { $0 }.joined(separator: " ")
        HStack(spacing: 6) {
            if spinning { ProgressView().controlSize(.mini).frame(width: 9, height: 9) } else { ToneDot(tone: status.tone) }
            Text(status.words).font(FormMetrics.detail).foregroundStyle(status.tone == .problem ? .orange : FleetStyle.muted).lineLimit(1)
        }
        .help(hover)
        .accessibilityElement(children: .ignore).accessibilityLabel([status.words, hover].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

/// A QR code of one text, black on white so that a phone can read it in the dark window.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 168
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable() }
            else { Color.white }
        }
        .frame(width: size, height: size)
        .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .accessibilityElement().accessibilityLabel("QR code")
        .task(id: text) { image = Self.image(text) }
    }

    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// The owner's link step of one app, in a channel's card: the message to send with Copy, a QR code of the agent's
/// own account, its link, and how long the code still works on the hub's clock, then Get new code.
struct OwnerLinkStep: View {
    @Bindable var store: FleetStore
    let app: String
    /// nil before Fleet has a code.
    let code: LinkCode?
    let target: LinkCode.Target?
    let making: Bool
    let canRenew: Bool
    let renew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Link your \(ChatApps.title(app))", systemImage: "person.crop.circle.badge.checkmark")
                .font(FormMetrics.title).foregroundStyle(FleetStyle.text)
            if let code {
                HStack(alignment: .top, spacing: 16) {
                    if let link = target?.link { QRCodeView(text: link.absoluteString, size: 112) }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Text("link \(code.display)").font(FormMetrics.title)
                                .foregroundStyle(FleetStyle.text).textSelection(.enabled).accessibilityIdentifier("channels-code-\(app)")
                            MessageAction(symbol: "square.on.square", label: "Copy the message") { copyMessage("link \(code.display)") }
                                .foregroundStyle(FleetStyle.muted)
                        }
                        if let link = target?.link {
                            Link(destination: link) { Label(app == "whatsapp" ? "Open WhatsApp" : "Open in Discord", systemImage: "arrow.up.right") }
                                .buttonStyle(FleetOutlineButtonStyle()).help(link.absoluteString)
                        } else {
                            Text("No link yet").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        }
                        countdown(code)
                    }
                }
            } else if making {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Making a code…") }
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            } else {
                Button("Get code") { renew() }.buttonStyle(FleetOutlineButtonStyle()).disabled(!canRenew)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .accessibilityElement(children: .contain).accessibilityIdentifier("channels-owner-link-\(app)")
    }

    /// "Works for 9:41" on the hub's clock, once a second; at the end, Get new code.
    private func countdown(_ code: LinkCode) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = ChatApps.remaining(expires: code.expires, serverTime: store.state?.time ?? Date().timeIntervalSince1970,
                                          readAt: store.lastSuccess ?? context.date, now: context.date)
            if left > 0 {
                Text("Works for \(ChatApps.countdown(left))").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).monospacedDigit()
            } else {
                HStack(spacing: 8) {
                    Text("Expired").font(FormMetrics.detail).foregroundStyle(.orange)
                    Button("Get new code") { renew() }.buttonStyle(FleetOutlineButtonStyle()).disabled(!canRenew)
                }
            }
        }
    }
}

/// Under a reply to a channel message: the channel's mark and the delivery as icons, with the words in the hover
/// text. Not sent or not confirmed is an orange exclamation mark, with Send again: only the owner decides to send a
/// part again whose outcome is not known.
struct DeliveryLine: View {
    @Bindable var store: FleetStore
    let delivery: ReportDelivery
    @State private var sending = false
    @State private var failure: String?
    /// The outbound item that was sent again: its button stays away until the hub's next state.
    @State private var sentAgain: Int?
    private let client = ChatAppsClient()

    private var offered: Bool { store.state?.ui_features?.contains(ChatApps.feature) == true }

    var body: some View {
        let words = delivery.words(time: messageTime)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    BrandMark(app: delivery.app, size: 11).foregroundStyle(FleetStyle.muted)
                    DeliveryIcon(state: delivery.state)
                }
                .help(words + (delivery.at.map { " · \(fleetDate($0))" } ?? ""))
                .accessibilityElement(children: .ignore).accessibilityLabel(words)
                if delivery.canSendAgain && offered && sentAgain != delivery.outbound {
                    MessageAction(symbol: "arrow.clockwise", label: "Send again", help: "Send again. The first one can still arrive.", height: 16) {
                        Task { await sendAgain() }
                    }.foregroundStyle(FleetStyle.muted).disabled(sending || !store.isFresh)
                }
                if sending { ProgressView().controlSize(.mini) }
            }
            if let failure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.font(FormMetrics.detail).padding(.top, 4)
            .accessibilityElement(children: .contain)
    }

    private func sendAgain() async {
        guard let outbound = delivery.outbound, let db = store.state?.db else { return }
        sending = true; failure = nil
        defer { sending = false }
        do {
            _ = try await client.sendAgain(hub: store.hub, database: db, client: store.installation, outbound: outbound)
            sentAgain = outbound
            await store.refresh()
        } catch { failure = ChatAppWords.reason(error) }
    }
}

/// A delivery state as an icon: a clock while it waits, one check when sent, two when delivered or read (its words on
/// hover say which), and an orange exclamation mark when it failed or is not confirmed.
private struct DeliveryIcon: View {
    let state: String

    var body: some View {
        Group {
            switch state {
            case "sent": Image(systemName: "checkmark").foregroundStyle(FleetStyle.muted)
            case "delivered": checks.foregroundStyle(FleetStyle.muted)
            // Read is a state, and a state is never violet (D-8): its word is on hover.
            case "read": checks.foregroundStyle(FleetStyle.muted)
            case "failed", "unknown": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            default: Image(systemName: "clock").foregroundStyle(FleetStyle.muted)
            }
        }.font(IconMetrics.symbol(10, weight: .semibold))
    }

    private var checks: some View {
        HStack(spacing: -5) { Image(systemName: "checkmark"); Image(systemName: "checkmark") }
    }
}

enum ChatAppWords {
    /// A refusal in the hub's words, or a write without an answer that can still arrive.
    static func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let text) = error { return "The hub said: \(text.hasSuffix(".") ? text : text + ".")" }
        if error is URLError { return "No answer from the hub. It can still do it: look again before you try again." }
        return error.localizedDescription
    }

    /// An agent's name as the pages show it.
    static func agent(_ name: String) -> String { name.agentLabel }
}
