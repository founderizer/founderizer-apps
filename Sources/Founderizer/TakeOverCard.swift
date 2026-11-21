import AppKit
import FleetCore
import SwiftUI

/// **The take-over card** (the owner's "Yes, build it" of 21 November 2026 to the pictures of
/// `superbot-ideas/09-take-over-modal-design.md`; his words: "a card that requires taking over should be MUCH easier
/// and I should be able to take over from that card directly! in a modal where I do that"): Take over on a request
/// opens the asking agent's screen in a card over the window, with ✓ Done, and no other window. The screen comes
/// straight from this Mac through the SSH tunnel that Take over opened before (`ScreenSharingSession.openTunnel`),
/// never through the hub.
struct TakeOverItem: Identifiable {
    /// The request's number.
    let id: Int
    /// The hub and fleet of the request: a card of another hub or fleet is no card of this one (`closeAnsweredTakeOvers`).
    let hub: URL
    let database: String?
    let agent: String
    let title: String
    let way: ScreenSharingConnection
    /// The request's own window, which steps aside while the card stands; nil for a press on Needs you or in a chat.
    let window: NeedWindowLink?
    /// The task's or job's card that stood over the window at the press, and the page under it: that card comes back
    /// when this card closes, on that page only.
    let detailUnder: DetailCard?
    let page: Destination
}

/// The newest whole screen of the session, waiting for the main thread: a screen that changes 60 times a second never
/// queues 60 pictures, and no screen is copied while one waits (`RFBSession.run`'s `wanted`).
final class TakeOverFrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: RFBFrame?

    /// Whether the session may give a screen: none waits now.
    var wanted: Bool { lock.withLock { frame == nil } }

    /// Keeps the frame; true when the main thread has no call on its way to take one.
    func put(_ frame: RFBFrame) -> Bool {
        lock.withLock {
            let first = self.frame == nil
            self.frame = frame
            return first
        }
    }

    func take() -> RFBFrame? {
        lock.withLock {
            defer { frame = nil }
            return frame
        }
    }
}

/// **What the card does**: the tunnel, the sign-in, the pictures, his input and his answer. The store holds it for
/// as long as the card stands (`FleetStore.takeOverScreen`), and stops it at the card's close, however it closes.
@MainActor @Observable final class TakeOverScreen {
    enum Phase: Equatable { case connecting, password, live, stopped }

    let item: TakeOverItem
    private(set) var phase: Phase = .connecting
    private(set) var image: CGImage?
    /// The card's one orange line, or nil while all is well.
    private(set) var problem: String?
    private(set) var answering = false
    @ObservationIgnored let input = RemoteInput()
    @ObservationIgnored private weak var store: FleetStore?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var answer: Task<Void, Never>?
    @ObservationIgnored private var session: RFBSession?
    @ObservationIgnored private var port: Int?
    @ObservationIgnored private let slot = TakeOverFrameSlot()
    @ObservationIgnored private var stopped = false

    init(item: TakeOverItem, store: FleetStore) {
        self.item = item
        self.store = store
    }

    /// A Mac's own screen signs in with that Mac's account; a Linux agent's screen with the one-time password that
    /// its server made for this card.
    private var isMac: Bool { item.way.agent == nil }

    func start() {
        guard work == nil, !stopped else { return }
        work = Task { await open() }
    }

    private func open() async {
        guard let store else { return }
        let result = await store.openTakeOverScreen(item)
        guard !Task.isCancelled, !stopped else { return }
        switch result {
        case .failure(let words):
            problem = words.text.isEmpty ? nil : words.text
            phase = .stopped
        case .success(let opened):
            port = opened.port
            if isMac {
                if let secret = TakeOverPasswords.read(item.way).map({ Secret(.account(user: item.way.user, password: $0),
                                                                              keep: nil) }) {
                    await connectAndRun(secret)
                } else {
                    phase = .password
                }
            } else if let secret = opened.password.map({ Secret(.password($0), keep: nil) }) {
                await connectAndRun(secret)
            } else {
                problem = String(l10n: "The agent's screen cannot be reached.")
                phase = .stopped
            }
        }
    }

    /// His Mac password, from the card's one field: kept only once it opened the screen.
    func signIn(password: String) {
        guard phase == .password, !password.isEmpty, !stopped else { return }
        problem = nil
        work?.cancel()
        let secret = Secret(.account(user: item.way.user, password: password), keep: password)
        work = Task { await connectAndRun(secret) }
    }

    /// The sign-in's secret, for as long as the sign-in needs it: emptied after it, so that the password does not
    /// live on through the whole session.
    private final class Secret {
        var credentials: RFBCredentials?
        var keep: String?
        init(_ credentials: RFBCredentials, keep: String?) { self.credentials = credentials; self.keep = keep }
    }

    private func connectAndRun(_ secret: Secret) async {
        guard let session = await connect(secret) else { return }
        await run(session)
    }

    /// The connection and the sign-in; nil with the card's line and phase set. The far end of the tunnel can still be
    /// starting (a Linux agent's screen that the hub opened for this card): a connection that ends before any sign-in
    /// is tried again, a few times; a screen that waits for its one sign-in keeps waiting through them
    /// (`05-probe-2-results.md`, section 9).
    private func connect(_ secret: Secret) async -> RFBSession? {
        defer { secret.credentials = nil; secret.keep = nil }
        guard let port, let credentials = secret.credentials else { return nil }
        phase = .connecting
        var tries = 0
        while true {
            tries += 1
            do {
                let session = RFBSession(transport: try await RFBLocalConnection.open(port: port))
                self.session = session
                guard !Task.isCancelled, !stopped else { await stopSession(); return nil }    // Esc while it opened
                _ = try await session.start(credentials: credentials)
                guard !Task.isCancelled, !stopped else { await stopSession(); return nil }
                if let keep = secret.keep { TakeOverPasswords.save(keep, for: item.way) }
                return session
            } catch RFBError.signInRefused {
                await stopSession()
                guard !Task.isCancelled, !stopped else { return nil }
                if isMac {
                    TakeOverPasswords.forget(item.way)
                    problem = String(l10n: "That password does not open this Mac's screen.")
                    phase = .password
                } else {
                    problem = String(l10n: "The agent's screen refused the sign-in.")
                    phase = .stopped
                }
                return nil
            } catch {
                await stopSession()
                guard !Task.isCancelled, !stopped else { return nil }
                if tries < 5, (error as? RFBError) == .closed {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return nil }
                    continue
                }
                problem = String(l10n: "The agent's screen cannot be reached.")
                phase = .stopped
                return nil
            }
        }
    }

    private func run(_ session: RFBSession) async {
        input.attach(session)
        phase = .live
        let slot = slot
        do {
            try await session.run(frames: { [weak self] frame in
                guard slot.put(frame) else { return }
                Task { @MainActor in self?.showNewest() }
            }, wanted: { slot.wanted })
        } catch {}
        input.detach()
        guard !Task.isCancelled, !stopped, phase == .live else { return }
        problem = String(l10n: "The connection to the agent's screen ended.")
        phase = .stopped
    }

    private func stopSession() async {
        let session = session
        self.session = nil
        await session?.stop()
    }

    private func showNewest() {
        guard phase == .live, let frame = slot.take() else { return }
        image = Self.picture(frame)
        if let session { Task { await session.catchUp() } }
    }

    static func picture(_ frame: RFBFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0, frame.pixels.count == frame.width * frame.height * 4,
              let provider = CGDataProvider(data: frame.pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.width * 4, space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// ✓ Done: the request's quick reply "Done", by the path of every answer (`FleetStore.answerTakeOver`). The card
    /// closes when the hub has it; it says at once when the answer must wait for the hub, and stays with its words
    /// when the answer does not go.
    func done() {
        guard !answering, !stopped, let store else { return }
        answering = true
        problem = nil
        let id = item.id
        answer = Task {
            let refusal = await store.answerTakeOver(id) { [weak self] in
                self?.problem = String(l10n: "The answer waits until the hub can take it.")
            }
            guard !Task.isCancelled, !stopped else { return }
            answering = false
            if let refusal { problem = refusal } else { store.closeTakeOverCard(id) }
        }
    }

    /// The card's end, however it closes (`FleetStore.takeOverCardClosed`): the work and the answer that waits stop,
    /// and the connection ends; the store closes the tunnel.
    func stop() {
        stopped = true
        work?.cancel()
        work = nil
        answer?.cancel()
        answer = nil
        input.detach()
        let session = session
        self.session = nil
        Task { await session?.stop() }
    }
}

struct TakeOverCard: View {
    let store: FleetStore
    let screen: TakeOverScreen
    @State private var password = ""

    private var item: TakeOverItem { screen.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ZStack {
                Color.black
                if screen.phase == .password {
                    passwordForm
                } else {
                    RemoteScreenView(image: screen.image, input: screen.input)
                    if screen.image == nil, screen.phase == .connecting {
                        ProgressView().controlSize(.regular).accessibilityLabel(Text("Connecting…"))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1))
            if let problem = screen.problem {
                Text(verbatim: problem).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .onAppear { screen.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentGlyph(name: item.agent, presence: .online, size: GlyphSize.inline, dot: false)
            Text(verbatim: item.agent.agentLabel).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
            Text(verbatim: item.title).font(FormMetrics.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button { screen.done() } label: { Label("Done", systemImage: "checkmark") }
                .buttonStyle(FleetPrimaryButtonStyle())
                .disabled(screen.answering)
                .accessibilityIdentifier("takeover-done-\(item.id)")
        }
        .font(FormMetrics.text)
    }

    /// A Mac's screen, the first time: that Mac's account password, once (the design's section 3.3).
    private var passwordForm: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(IconMetrics.symbol(22)).foregroundStyle(FleetStyle.muted)
            Text(verbatim: machineLine).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            SetupSecureField(placeholder: String(l10n: "Password"), text: $password) { submit() }
                .frame(width: 240)
            Button("Continue") { submit() }
                .buttonStyle(FleetPrimaryButtonStyle())
                .disabled(password.isEmpty)
        }
        .padding(20)
    }

    private var machineLine: String {
        let machine = store.runMachines?.first(where: { $0.agent == item.agent })?.machine
        return [machine, item.way.user].compactMap { $0 }.joined(separator: " · ")
    }

    private func submit() {
        let typed = password
        password = ""
        screen.signIn(password: typed)
    }
}
