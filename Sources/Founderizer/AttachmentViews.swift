import AppKit
import FleetCore
import SwiftUI
import UniformTypeIdentifiers

/// The plus of a composer: the owner picks files to send with the message (owner feature `attachments`). What
/// comes back goes to the store, which writes the bytes on this Mac before anything travels. A file can also be
/// dropped on the composer or anywhere in the conversation, and a picture pasted with Cmd+V.
struct AttachFilesButton: View {
    @Bindable var store: FleetStore
    /// The composer that the files belong to: one chat, or one open request of Needs you.
    let composer: String
    @State private var picking = false

    private var room: Int { max(0, MessageAttachment.perMessage - store.stagedFiles(for: composer).count) }
    private var words: String {
        room > 0 ? String(l10n: "Send a picture, a PDF, a ZIP or a text file with this message")
                 : String(l10n: "A message carries at most \(MessageAttachment.perMessage) files")
    }

    var body: some View {
        IconButton(symbol: "plus", words: words, size: 14,
                   tint: room > 0 ? FleetStyle.muted : Color(white: 0.35)) { picking = true }
        .disabled(room == 0 || store.storageError != nil)
        .accessibilityLabel("Attach a file")
        .accessibilityIdentifier("attach-file")
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result { store.setFileError(error.localizedDescription, for: composer) }
                return
            }
            Task { for url in urls.prefix(room) { await store.stage(contentsOf: url, for: composer) } }
        }
    }

    /// The types that the hub takes, as the open panel names them.
    static let types: [UTType] = [.png, .jpeg, .gif, .webP, .pdf, .zip, .plainText, .commaSeparatedText, .json,
                                  UTType(filenameExtension: "md") ?? .plainText]
}

/// The files that wait in one composer: a picture shows itself, another file its kind. Each says when it is going up
/// or did not go, and the x takes it out again.
struct StagedFilesStrip: View {
    @Bindable var store: FleetStore
    let composer: String
    /// nil: the files that still wait in the composer. A list of numbers: only those files, as a message that is on
    /// its way shows them, and none of them can be taken out any more.
    var sending: [Int]?

    private var files: [FleetStore.StagedFile] {
        let onItsWay = store.pending?.attachments ?? []
        return store.stagedFiles(for: composer).filter { file in
            guard let id = file.attachmentID else { return sending == nil }
            return sending.map { $0.contains(id) } ?? !onItsWay.contains(id)
        }
    }

    var body: some View {
        if !files.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(files) { chip($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ file: FleetStore.StagedFile) -> some View {
        HStack(spacing: 8) {
            picture(file)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(ChatStyle.detail).foregroundStyle(FleetStyle.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(words(file)).font(ChatStyle.detail)
                    .foregroundStyle(file.failure == nil ? FleetStyle.muted : .orange)
            }
            if sending == nil {
                if file.failure != nil {
                    IconButton(symbol: "arrow.clockwise", words: String(l10n: "Send this file up again"), size: 10,
                               side: IconMetrics.small, tint: FleetStyle.accent) {
                        Task { await store.upload(file, for: composer) }
                    }
                }
                IconButton(symbol: "xmark", words: String(l10n: "Take \(file.name) out"), size: 9.5,
                           side: IconMetrics.small) {
                    store.removeStaged(file, for: composer)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: 190)
        .background(FleetStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .accessibilityIdentifier("staged-\(file.name)")
    }

    private func words(_ file: FleetStore.StagedFile) -> String {
        if let failure = file.failure { return failure.count > 28 ? String(l10n: "Not sent") : failure }
        if store.uploading.contains(file.requestID) { return String(l10n: "Going up…") }
        return file.isOnHub ? MessageAttachment.sizeWords(file.size) : String(l10n: "Waiting")
    }

    @ViewBuilder private func picture(_ file: FleetStore.StagedFile) -> some View {
        if file.mime.hasPrefix("image/"), let data = try? Data(contentsOf: store.stagedURL(file)),
           let small = MessageAttachment.thumbnail(data, maxPixels: 64) {
            Image(decorative: small, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
        } else {
            Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                .font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted).frame(width: 26, height: 26)
        }
    }
}

/// What the owner presses beside one file he attached (owner feature `attachment_knowledge`, UI-API.md 1.30 and
/// 1.31). The hub lets a file go ninety days after the message that carried it, so this is how he says "keep this
/// one": the file itself, which is the only way for a picture, a mockup, a zip or a PDF, or -- for one of the four
/// text types -- its words as one of his own knowledge files, with the original kept beside them. The first press
/// is also the way back, because a kept file stays in the hub's folder for ever otherwise and that folder is in no
/// copy of the fleet.
///
/// A kept file says so without being hovered, because that is a fact about the file; the presses show under the
/// pointer, as a message's own footer does, and the row keeps its space so hover never moves the chat.
struct KeepFileRow: View {
    @Bindable var store: FleetStore
    let file: MessageAttachment
    let hovered: Bool
    /// The row's height, kept whether it shows or not; with the 1 point over it, what it adds under a file.
    static let height: CGFloat = 20

    private var shows: Bool { file.isKept || hovered }

    var body: some View {
        if store.supportsKeptFiles {
            HStack(spacing: 5) {
                if file.isKept {
                    Text(file.keptAs == nil ? "Kept" : "Kept as knowledge").font(ChatStyle.detail)
                }
                MessageAction(symbol: file.isKept ? "bookmark.fill" : "bookmark",
                              label: file.isKept ? String(l10n: "Stop keeping \(file.name)") : String(l10n: "Keep \(file.name)"),
                              help: keepHelp) {
                    Task { await store.keep(file, !file.isKept) }
                }
                .disabled(store.keeping.contains(file.id))
                .accessibilityIdentifier("keep-file-\(file.id)")
                // Only a file that is not kept yet, because the hub refuses this one for a file it already keeps
                // (409), and only a type whose words can be text that search_knowledge reads (415 otherwise).
                if !file.isKept, file.canBecomeKnowledge {
                    MessageAction(symbol: "text.book.closed", label: String(l10n: "Keep \(file.name) as knowledge"),
                                  help: String(l10n: "Keep the words of \(file.name) as one of your own knowledge files, with the file itself beside them. Your manager reads them.")) {
                        Task { await store.keepAsKnowledge(file) }
                    }
                    .disabled(store.keeping.contains(file.id))
                    .accessibilityIdentifier("keep-knowledge-\(file.id)")
                }
            }
            // Kept is a state, so it is muted as the rest (D-8: a state is never violet); its filled mark and "Kept"
            // say it.
            .foregroundStyle(FleetStyle.muted)
            .frame(height: Self.height)
            .opacity(shows ? 1 : 0).allowsHitTesting(hovered)
            .accessibilityHidden(!shows)
        }
    }

    private var keepHelp: String {
        if let path = file.keptAs {
            return String(l10n: "Stop keeping the original of \(file.name) on the hub. \(path) stays in your knowledge.")
        }
        if file.isKept {
            return String(l10n: "Stop keeping \(file.name). The hub lets it go with its message again, as it does every file.")
        }
        return String(l10n: "Keep \(file.name) on the hub. Without this the hub lets it go ninety days after its message, and it is in no copy of your fleet.")
    }
}

/// The files of one message, under its text: a picture is shown, another file is a row with its kind, its name and
/// its size. A click opens it in the Mac's own viewer, from bytes whose SHA-256 the app checked. Under each file,
/// what the owner presses to keep it past the ninety days (`KeepFileRow`).
struct MessageFilesView: View {
    @Bindable var store: FleetStore
    let files: [MessageAttachment]
    var alignment: HorizontalAlignment = .trailing
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(files) { file in
                VStack(alignment: alignment, spacing: 1) {
                    Button { open(file) } label: { item(file) }
                        .buttonStyle(.plain)
                        .help("Open \(file.name) (\(file.sizeWords))")
                        .accessibilityIdentifier("file-\(file.id)")
                    // What he did to this file and did not happen, under the file itself and in no composer.
                    if let problem = store.fileProblems[file.id] {
                        Text(problem).font(ChatStyle.detail).foregroundStyle(.orange).padding(.vertical, 2)
                    }
                    KeepFileRow(store: store, file: file, hovered: hovered == file.id)
                }
                .contentShape(Rectangle())
                .onHover { over in
                    if over { hovered = file.id } else if hovered == file.id { hovered = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    @ViewBuilder private func item(_ file: MessageAttachment) -> some View {
        if file.isImage {
            PictureTile(store: store, file: file, side: alignment)
        } else {
            HStack(spacing: 9) {
                Image(systemName: file.symbol).font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(ChatStyle.detail).foregroundStyle(FleetStyle.text)
                        .lineLimit(1).truncationMode(.middle)
                    // "Not loaded" as a picture's tile says it (fix round 3, item 4): orange while the hub answers.
                    let unloaded = store.unloadedFiles.contains(file.id)
                    Text(unloaded ? String(l10n: "Not loaded") : file.sizeWords).font(ChatStyle.detail)
                        .foregroundStyle(unloaded && store.isFresh ? Color.orange : FleetStyle.muted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(FleetStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .frame(maxWidth: 280, alignment: .leading)
            .task(id: store.isFresh) { if store.isFresh { await store.load(file) } }
        }
    }

    /// The Mac's own viewer opens a file, never an address: the bytes come from the hub, checked, and are written
    /// where only this user can read them.
    private func open(_ file: MessageAttachment) {
        Task {
            await store.load(file)
            guard let data = store.fileData[file.id] else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-attachments",
                                                                                       isDirectory: true)
            let place = folder.appendingPathComponent("\(file.id)-\(file.name)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: place, options: [.atomic])
                NSWorkspace.shared.open(place)
                store.setFileProblem(nil, for: file.id)
            } catch { store.setFileProblem(String(l10n: "This file did not open on this Mac."), for: file.id) }
        }
    }
}

/// **A picture of a message keeps its place from the first frame** (the loading contract, B-MOT-11): one box in the chat,
/// as wide as the widest picture it draws (16 by 9 at 210 points) and 210 points high, **drawn in the bubble's fill with
/// the picture's mark until the picture comes** (fix round 3, item 45: the phone's look, one look on both apps; T-34) —
/// nothing else for the first second of the read, then the read's words, moving, under the mark — then the picture, as
/// wide as it is at that height up to 16 by 9, on the message's side, in the plate's place. **A wider one is drawn
/// whole**, at that widest width and shorter than its place, at the top of the place: cut to its middle, it lost what
/// stood at its two ends. The place stood empty until the picture came, where the phone drew its grey box with the mark.
/// A message does not say how large its picture is, so the place is this one box; when the hub gives a picture's size
/// (T-34, a hub item) the place can take it instead (`place`). **In a column narrower than the box the place is the
/// column's width** (fix round 2): its fixed 373 points made the whole chat wider than its column at a 960-point
/// window, so his bubbles and the request cards ran under the panel. A picture that did not come is the approved tile
/// in that plate (`plate`).
private struct PictureTile: View {
    let store: FleetStore
    let file: MessageAttachment
    /// The message's side: his own on the right, an agent's on the left.
    let side: HorizontalAlignment
    @State private var slow = false
    /// The picture did not come and its tile said so: from then on the plate keeps the file's name until the picture
    /// comes, also while it is read again (fix round 3, items 4 and 15).
    @State private var tiled = false
    /// When the tile's read again began, while it is on its way: ↻'s, or the one when the hub answers again.
    @State private var rereadSince: ContinuousClock.Instant?
    /// When "Reading…" last drew, a frame after it came: what the read brings waits until it has stood half a second.
    @State private var wordsDrawn: ContinuousClock.Instant?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 210, widest: CGFloat = 210 * 16 / 9

    /// The place of a picture in the chat: the one box, whatever its picture turns out to be.
    static var place: CGSize { CGSize(width: widest, height: height) }

    var body: some View {
        // **"Reading…" stands half a second once it drew** (fix round 3b; D-1 rule 1, as a loading line's `settle`): the
        // picture, or "Not loaded", waits for it. It stood 0.45–0.55 s on a 1.5-s read, and 10–45 ms after ↻.
        let wordsStand = wordsDrawn.map { !QuietClock.shared.passed($0 + LoadingLine.stands) } ?? false
        let data = wordsStand ? nil : store.fileData[file.id]
        let picture = data.flatMap { MessageAttachment.thumbnail($0, maxPixels: 720) }
        // A read that failed, or one that cannot go while the hub is away.
        let failed = !wordsStand && data == nil && (store.unloadedFiles.contains(file.id) || !store.isFresh)
        // A stack, so the reads below stay one through the picture's states.
        ZStack {
            if let picture {
                let ratio = max(CGFloat(picture.width) / CGFloat(max(1, picture.height)), 0.01)
                // Whole, at its own proportions, as large as the place allows: the place's height, and its width, which
                // is the column's where the column is narrower.
                Image(decorative: picture, scale: 1).resizable().aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: min(Self.widest, Self.height * ratio))
                    .clipShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                    .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
            } else {
                plate(data: data, failed: failed)
            }
        }
        // The picture at the top of its place, on the message's side; the plate fills the place. The place takes the room
        // it is given up to its own width, and never more.
        .frame(maxWidth: Self.place.width, minHeight: Self.place.height, maxHeight: Self.place.height,
               alignment: Alignment(horizontal: side, vertical: .top))
        // Read again when the hub answers again, so a picture that did not come while it was away comes by itself.
        .task(id: store.isFresh) { if store.isFresh { await read() } }
        .task {
            do { try await Task.sleep(for: LoadingLine.quiet) } catch { return }
            slow = true
        }
        .onChange(of: failed, initial: true) { _, now in if now { tiled = true } }
        .onChange(of: data != nil) { _, now in if now { tiled = false } }
    }

    /// "Reading…" came: it is on the screen a frame later (`LoadingLine.shownAt`).
    private func noteWords() { wordsDrawn = ContinuousClock.now + .milliseconds(17) }

    /// One read of the picture; a read after its tile showed keeps the tile, with its words a second after it began.
    private func read() async {
        if tiled { rereadSince = .now }
        await store.load(file)
        rereadSince = nil
    }

    /// **The picture's place until it comes: the bubble's fill, and the file's mark in its middle** (item 45), with one or
    /// two lines under the mark in a room of two, so the mark stands at one place in every state. While the picture is on
    /// its way: nothing for the read's first second, then "Reading…". **A picture that did not come is the approved
    /// tile** (D-7 item 8; items 4 and 15): the file's name, and "Not loaded" under it — orange while the hub answers,
    /// with the 28-point ↻ at the plate's top right that reads it again (the owner's yes of 28 October 2026); muted and
    /// without ↻ while the hub is away, when the notice over the page is the one sign of the outage and the tile reads
    /// again by itself when the hub answers (T-14). "Not loaded" and ↻ floated in an empty place. **A read after it keeps
    /// the name without its words and ↻, and says "Reading…" only once the read has had a second** (D-1 rule 1): the
    /// words came in the frame after ↻, and a read that answers inside the second flashed them.
    private func plate(data: Data?, failed: Bool) -> some View {
        let reading = rereadSince != nil || !failed
        return VStack(spacing: 6) {
            Image(systemName: file.symbol).font(IconMetrics.symbol(20)).foregroundStyle(FleetStyle.muted)
            ZStack(alignment: .top) {
                VStack(spacing: 1) { Text(verbatim: " "); Text(verbatim: " ") }.font(ChatStyle.detail).hidden()
                VStack(spacing: 1) {
                    if data != nil {
                        // Bytes that are no picture this Mac can draw: its size, as any other file says it.
                        Text(file.sizeWords).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                    } else if failed || tiled {
                        Text(file.name).font(ChatStyle.detail).foregroundStyle(FleetStyle.text)
                            .lineLimit(1).truncationMode(.middle)
                        if reading {
                            Held(since: rereadSince) { ReadingWords().onAppear(perform: noteWords) }
                        } else {
                            Text("Not loaded").font(ChatStyle.detail)
                                .foregroundStyle(store.isFresh ? Color.orange : FleetStyle.muted)
                        }
                    } else if slow {
                        ReadingWords().transition(.opacity).onAppear(perform: noteWords)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: slow)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FleetStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .overlay(alignment: .topTrailing) {
            // Only while it can act: the hub answers and no read is on its way.
            if !reading, store.isFresh, store.unloadedFiles.contains(file.id) {
                IconButton(symbol: "arrow.clockwise", words: String(l10n: "Read \(file.name) again"), size: 12) {
                    Task { await read() }
                }
                .environment(\.onCard, true)
                .padding(6)
                .accessibilityIdentifier("reload-file-\(file.id)")
            }
        }
    }
}

/// "Reading…" in a picture's place: the moving words of a wait, still under Reduce Motion.
private struct ReadingWords: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion { Text("Reading…").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
        else { ShimmeringWords(text: String(l10n: "Reading…")) }
    }
}

/// What the clipboard holds for a composer: files of this Mac, or the bytes of one picture. Plain text gives
/// nothing, so a text paste stays the text field's own.
enum PastedFiles {
    case files([URL])
    case picture(Data)

    static func onClipboard(_ pasteboard: NSPasteboard = .general) -> PastedFiles? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        for kind: NSPasteboard.PasteboardType in [.png, .tiff] {
            if let data = pasteboard.data(forType: kind), !data.isEmpty { return .picture(data) }
        }
        return nil
    }
}

/// The clipboard into one composer: a file takes the path of a picked file, and a picture the bytes that travel
/// well. Both go through the store's own staging, so the size and the type rules, and the words of a refusal, are
/// the ones that the plus and a dropped file have.
@MainActor func stagePasted(_ pasted: PastedFiles, store: FleetStore, composer: String) async {
    switch pasted {
    case .files(let urls):
        for url in urls.prefix(MessageAttachment.perMessage) { await store.stage(contentsOf: url, for: composer) }
    case .picture(let data):
        guard let picture = try? MessageAttachment.imageForSending(data) else {
            store.setFileError(AttachmentError.type.errorDescription, for: composer)
            return
        }
        await store.stage(picture.data, name: "pasted-picture", mime: picture.mime, for: composer)
    }
}

/// Cmd+V in a composer: a picture or a file on the clipboard becomes an attachment of that composer. The Mac gives
/// the Paste of the menu to the field editor, which takes no picture, so the composer watches the key itself, before
/// the menu sees it; a paste that holds neither picture nor file goes on to the text field as text.
struct PasteAttachments: ViewModifier {
    @Bindable var store: FleetStore
    /// The composer that the clipboard reaches, or nil while this view takes no file: one window holds several
    /// composers — the open requests of Needs you — and the one that the owner writes in takes the paste.
    let composer: String?
    @State private var watch: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onDisappear { stop() }
            .onChange(of: composer) { _, _ in stop(); start() }
    }

    private func start() {
        guard watch == nil, let composer else { return }
        let store = store
        watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The monitor runs on the main thread, before the menu sees the key.
            let taken = MainActor.assumeIsolated { () -> Bool in
                // Cmd+V alone. Caps Lock does not count, and Cmd+Shift+V (paste as text) stays the text field's.
                let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .function, .numericPad])
                guard keys == .command, !event.isARepeat,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      store.supportsAttachments, store.storageError == nil,
                      let pasted = PastedFiles.onClipboard() else { return false }
                Task { await stagePasted(pasted, store: store, composer: composer) }
                return true
            }
            return taken ? nil : event
        }
    }

    private func stop() {
        if let watch { NSEvent.removeMonitor(watch) }
        watch = nil
    }
}

/// What a view shows while a file is over it: the dashed frame of a drop and the words of what the drop does.
struct DropMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: FormMetrics.radius, style: .continuous)
            .strokeBorder(FleetStyle.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .padding(10)
            .overlay {
                Label("Add to this message", systemImage: "plus")
                    .font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(FleetStyle.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(FleetStyle.line, lineWidth: 0.5))
            }
            .allowsHitTesting(false)
    }
}

/// A file dropped on this view is staged in one composer, with the rules and the words of a file picked with the
/// plus. `mark` is for the wide place around a composer — a conversation, an open request — which says what the
/// drop does while the file is over it; a composer itself takes the file without a mark.
struct StageDroppedFiles: ViewModifier {
    @Bindable var store: FleetStore
    /// The composer that the file reaches, or nil while this view takes no file.
    let composer: String?
    var mark = false
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let composer, store.supportsAttachments else { return false }
                Task { for url in urls.prefix(MessageAttachment.perMessage) {
                    await store.stage(contentsOf: url, for: composer)
                } }
                return true
            } isTargeted: { over = $0 && mark && composer != nil && store.supportsAttachments }
            .overlay { if over { DropMark() } }
    }
}

extension View {
    /// Cmd+V stages a picture or a file in this composer (`PasteAttachments`); nil takes no file.
    func pasteAttachments(store: FleetStore, composer: String?) -> some View {
        modifier(PasteAttachments(store: store, composer: composer))
    }

    /// A file dropped here is staged in this composer (`StageDroppedFiles`); nil takes no file.
    func stageDroppedFiles(store: FleetStore, composer: String?, mark: Bool = false) -> some View {
        modifier(StageDroppedFiles(store: store, composer: composer, mark: mark))
    }
}
