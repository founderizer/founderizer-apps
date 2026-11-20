import AppKit
import FleetCore
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// The plus of a composer: the owner picks files to send with the message (owner feature `attachments`). What
/// comes back goes to the store, which writes the bytes on this Mac before anything travels. A file can also be
/// dropped on the composer or anywhere in the conversation, and a picture pasted with Cmd+V.
struct AttachFilesButton: View {
    @Bindable var store: FleetStore
    /// The composer that the files belong to: one chat, one open request of Needs you, or one task's guidance.
    let composer: String
    @State private var picking = false

    private var room: Int { max(0, MessageAttachment.perMessage - store.stagedFiles(for: composer).count) }
    /// A task's guidance (`FleetStore.stageKey(task:database:)`), and the files that it takes
    /// (`FleetStore.filesTaken`): its session may open only pictures and texts, or only texts.
    private var guidance: Bool { composer.hasPrefix("task:") }
    private var taken: GuidanceFiles { store.filesTaken(by: composer) }
    private var words: String {
        if room == 0 {
            return guidance ? String(l10n: "Guidance carries at most \(MessageAttachment.perMessage) files")
                            : String(l10n: "A message carries at most \(MessageAttachment.perMessage) files")
        }
        switch taken {
        case .texts: return String(l10n: "Send a text file with this guidance")
        case .shown: return String(l10n: "Send a picture or a text file with this guidance")
        case .any where store.supportsOfficeFiles:
            return guidance ? String(l10n: "Send a picture, a PDF, an Office file, a ZIP or a text file with this guidance")
                            : String(l10n: "Send a picture, a PDF, an Office file, a ZIP or a text file with this message")
        case .any: return guidance ? String(l10n: "Send a picture, a PDF, a ZIP or a text file with this guidance")
                                   : String(l10n: "Send a picture, a PDF, a ZIP or a text file with this message")
        }
    }

    var body: some View {
        IconButton(symbol: "plus", words: words, size: 14,
                   tint: room > 0 ? FleetStyle.muted : Color(white: 0.35)) { picking = true }
        .disabled(room == 0 || store.storageError != nil)
        .accessibilityLabel("Attach a file")
        .accessibilityIdentifier("attach-file")
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types(taken, office: store.supportsOfficeFiles),
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result { store.setFileError(error.localizedDescription, for: composer) }
                return
            }
            // A pick is one batch: the words of a file that it refuses stay while the next file of it goes in.
            store.setFileError(nil, for: composer)
            Task { for url in urls.prefix(room) { await store.stage(contentsOf: url, for: composer) } }
        }
    }

    /// The types that the hub takes, as the open panel names them.
    static let types: [UTType] = [.png, .jpeg, .gif, .webP, .pdf, .zip, .plainText, .commaSeparatedText, .json,
                                  UTType(filenameExtension: "md") ?? .plainText]
    /// Word, Excel and PowerPoint, for a hub with the feature `office_files` (`MessageAttachment.sendable`).
    static let officeTypes: [UTType] = MessageAttachment.agentTypes.values.sorted().compactMap { UTType(filenameExtension: $0) }
    /// The types of the open panel for the files that a composer takes (`GuidanceFiles`).
    static func types(_ taken: GuidanceFiles, office: Bool = false) -> [UTType] {
        switch taken {
        case .any: office ? types + officeTypes : types
        case .shown: types.filter { $0 != .pdf && $0 != .zip }
        case .texts: types.filter { ![.png, .jpeg, .gif, .webP, .pdf, .zip].contains($0) }
        }
    }
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
        if file.mime.hasPrefix("image/"),
           let data = KeptFile.bytes(of: store.stagedURL(file), atMost: MessageAttachment.sizeLimit),
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
/// its size. **A click opens it in the Mac's preview window over the app** (Quick Look: every page of a PDF, the
/// picture at its size, with the window's own Open with Preview and Share; Esc closes it; the owner's yes of 18
/// November 2026, which replaced the open in the Preview app outside Founderizer), from bytes whose SHA-256 the app
/// checked. Under each of his own files, what the owner presses to keep it past the ninety days (`KeepFileRow`);
/// **an agent's file has a save icon** (the same yes): at the end of a file's row at rest, beside the eye that every
/// file's row has (`FileRowLook`, the owner's "I need a download icon/button too!" of 20 November 2026), and at the top
/// right of a picture while the pointer is on it. It writes the file into Downloads, never over a file that is there,
/// and "Saved to Downloads" shows under it. **An agent's file also drags out of the chat** (the same yes) to Finder, or to any other
/// app outside Founderizer, as the file itself (`ChatFileDrag`), and no place inside the app takes it.
struct MessageFilesView: View {
    @Bindable var store: FleetStore
    let files: [MessageAttachment]
    var alignment: HorizontalAlignment = .trailing
    /// The keep presses under each file, for his own files. An agent's file (CHAT-APPS.md 20) has no keep presses,
    /// and has the save icon in their place: `keeps` is false for an agent's files only.
    var keeps = true
    /// A guidance's files in a task's thread: neither the keep presses nor the save icon, as the owner's pictures of
    /// them showed (his "Yes, build it" of 19 November 2026).
    var plain = false
    @State private var hovered: Int?
    /// The file that the preview window shows now; nil when it is closed.
    @State private var opened: URL?
    /// The files that this view saved to Downloads: each says so under it.
    @State private var saved: Set<Int> = []
    /// The saves on their way: a second press while one runs makes no second copy.
    @State private var saving: Set<Int> = []

    private var saves: Bool { !keeps && !plain }

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(files) { file in
                VStack(alignment: alignment, spacing: 1) {
                    // The drag is on the button's content: on the button itself, a press that moved began no drag.
                    Button { open(file) } label: { item(file).dragsOut(saves ? file : nil, store: store) { hovered = nil } }
                        .buttonStyle(.plain)
                        .help("Open \(file.name) (\(file.sizeWords))")
                        .accessibilityIdentifier("file-\(file.id)")
                        .accessibilityActions {
                            if saves { Button("Save to Downloads") { save(file) } }
                        }
                    // What he did to this file and did not happen, under the file itself and in no composer.
                    if let problem = store.fileProblems[file.id] {
                        Text(problem).font(ChatStyle.detail).foregroundStyle(.orange).padding(.vertical, 2)
                    } else if saved.contains(file.id) {
                        Text("Saved to Downloads").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                            .padding(.vertical, 2)
                    }
                    if keeps && !plain { KeepFileRow(store: store, file: file, hovered: hovered == file.id) }
                }
                .contentShape(Rectangle())
                .onHover { over in
                    if over { hovered = file.id } else if hovered == file.id { hovered = nil }
                    // An agent's file that the app does not hold reads its bytes while the pointer is on it, so a drag
                    // finds them; a file that it holds costs nothing here.
                    if over, saves, store.isFresh, store.fileData[file.id] == nil { Task { _ = await store.bytes(of: file) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .quickLookPreview($opened)
    }

    @ViewBuilder private func item(_ file: MessageAttachment) -> some View {
        if file.isImage {
            PictureTile(store: store, file: file, side: alignment,
                        save: saves && hovered == file.id ? { save(file) } : nil)
        } else {
            // "Not loaded" as a picture's tile says it (fix round 3, item 4): orange while the hub answers.
            let unloaded = store.unloadedFiles.contains(file.id)
            FileRowLook(name: file.name, symbol: file.symbol, detail: unloaded ? String(l10n: "Not loaded") : file.sizeWords,
                        late: unloaded && store.isFresh, hovered: hovered == file.id,
                        open: { open(file) }, save: saves ? { save(file) } : nil, saveWords: String(l10n: "Save \(file.name) to Downloads"),
                        openWords: String(l10n: "Open \(file.name) (\(file.sizeWords))"), saveID: "save-file-\(file.id)")
                .task(id: store.isFresh) { if store.isFresh { await store.load(file) } }
        }
    }

    /// The preview window shows a file, never an address: the bytes come from the hub, checked, and are written where
    /// only this user can read them, under the file's own name, which is the window's title.
    private func open(_ file: MessageAttachment) {
        Task {
            guard let data = await store.bytes(of: file) else { return }
            let result = await Task.detached(priority: .userInitiated) { Result { try ChatFileCopy.written(data, of: file) } }.value
            switch result {
            case .success(let place):
                opened = place
                store.setFileProblem(nil, for: file.id)
            case .failure:
                store.setFileProblem(String(l10n: "This file did not open on this Mac."), for: file.id)
            }
        }
    }

    /// Into Downloads, as a browser saves a download: under the file's name, with " 2" before the extension when that
    /// name is taken there, and with the mark of a download (`ChatFileCopy.markDownloaded`). The write runs off the main
    /// thread: the first one asks macOS for Downloads, and the app does not stop while that question waits.
    private func save(_ file: MessageAttachment) {
        guard !saving.contains(file.id) else { return }
        saving.insert(file.id)
        Task {
            defer { saving.remove(file.id) }
            var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
            if let data = await store.bytes(of: file) {
                let name = file.name
                result = await Task.detached(priority: .userInitiated) {
                    Result {
                        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                        else { throw CocoaError(.fileNoSuchFile) }
                        let place = try MessageAttachment.save(data, named: name, in: downloads)
                        try ChatFileCopy.marked(place)
                        return place
                    }
                }.value
            }
            switch result {
            case .success:
                store.setFileProblem(nil, for: file.id)
                saved.insert(file.id)
            case .failure(let error):
                saved.remove(file.id)
                // macOS asks once whether Founderizer may use Downloads; after a no, each write is refused.
                let refused = (error as? CocoaError)?.code == .fileWriteNoPermission
                store.setFileProblem(refused
                    ? String(l10n: "macOS does not let Founderizer save in Downloads. Allow it in System Settings, Privacy & Security, Files & Folders.")
                    : String(l10n: "This file was not saved."), for: file.id)
            }
        }
    }
}

/// The app's own copies of a chat's files, for the preview window: one folder for each file under this user's temporary
/// folder, which only this user can read.
enum ChatFileCopy {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fleet-attachments", isDirectory: true)
    }

    /// The file under its own name, with the mark of a download.
    static func written(_ data: Data, of file: MessageAttachment) throws -> URL {
        let place = folder.appendingPathComponent(String(file.id), isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let copy = place.appendingPathComponent(MessageAttachment.diskName(file.name), isDirectory: false)
        try data.write(to: copy, options: [.atomic])
        try marked(copy)
        return copy
    }

    /// The mark of a download on this file, checked: a file with no mark is removed and never given out. Since a chat
    /// app's file of any type comes (CHAT-APPS.md 8.1), a stranger's `.terminal` or `.fileloc` with no mark would open
    /// with no question of Gatekeeper's.
    nonisolated static func marked(_ place: URL) throws {
        markDownloaded(place)
        guard getxattr(place.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else {
            try? FileManager.default.removeItem(at: place)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// A copy for one drag, in a new folder of its own: Finder copies it after the drop, and no open and no later drag
    /// writes over it in that time. A copy that has no mark of a download is never given out. As a new drag begins, the
    /// copies of drags of more than a day ago go, but not one that changed after it was written: an app that the file
    /// was dropped on may have opened it where it is. The folder is this user's temporary folder all the same, which
    /// macOS clears by its own rules, so a file that matters is the one in Finder.
    static func forDrag(_ data: Data, of file: MessageAttachment) throws -> URL {
        let drags = folder.appendingPathComponent("drag", isDirectory: true)
        let manager = FileManager.default
        let dayAgo = Date(timeIntervalSinceNow: -86_400)
        for old in (try? manager.contentsOfDirectory(at: drags, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            // Only the folder as the drag left it, or empty: its one copy, not changed after the folder was made. An
            // app that saves by writing a new file keeps both of that file's dates new, so the folder's own date decides.
            guard let made = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate, made < dayAgo,
                  let inside = try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            let untouched = inside.isEmpty || (inside.count == 1
                && (try? inside[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map { $0.timeIntervalSince(made) < 2 } == true)
            if untouched { try? manager.removeItem(at: old) }
        }
        let place = drags.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: place, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = place.appendingPathComponent(MessageAttachment.diskName(file.name), isDirectory: false)
        try data.write(to: copy, options: [.withoutOverwriting])
        markDownloaded(copy)
        guard getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else {
            try? manager.removeItem(at: place)
            throw CocoaError(.fileWriteUnknown)
        }
        return copy
    }

    /// The mark that a browser puts on a download (`com.apple.quarantine`): macOS treats the file as one that came from
    /// elsewhere, and a copy in Finder keeps the mark. An agent's file comes from outside this Mac.
    nonisolated static func markDownloaded(_ place: URL) {
        var url = place
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Founderizer",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? url.setResourceValues(values)
    }
}

/// An agent's file dragged out of the chat (the owner's yes of 18 November 2026: "You can also drag the file to
/// Finder."). **AppKit's own drag, which may end outside the app only**: in Finder, which copies the file (the live
/// check), or in another app outside Founderizer that takes a file (not checked), which may open it where it is. A
/// SwiftUI drag
/// (`onDrag`) also ended inside the app, and the message box took the file's address there as text; its file promise
/// landed in Finder with no mark of a download and the extension twice (the live check of 18 November 2026). The drag
/// carries the place of a copy of its own (`ChatFileCopy.forDrag`), written as the drag begins from bytes that match the
/// file's size and SHA-256 then, under the file's own name and with the mark of a download, and `marker`, which the chat's own drop
/// (`StageDroppedFiles`) refuses as well. A file whose bytes the app does not hold at that moment (a read that failed,
/// or one past the 16 newest) does not drag this time and is read at once, so the next drag carries it: a drag that
/// waited for the hub would stop the app until the hub answered.
@MainActor final class ChatFileDrag: NSObject, NSDraggingSource {
    static let marker = NSPasteboard.PasteboardType("com.founderizer.chat-file")
    private static let source = ChatFileDrag()

    /// Begins the drag of `file` from the press that moves now. False when no drag began.
    static func begin(_ file: MessageAttachment, store: FleetStore) -> Bool {
        // The bytes held under this number, only when they are this file's: a new fleet numbers its files from 1 again.
        guard let data = store.fileData[file.id], file.matches(data) else {
            Task { _ = await store.bytes(of: file) }
            return false
        }
        // Only from the event that moved the press, in the window that it came to: a session needs a press or a drag
        // of the pointer, and one begun from another event would keep the file under the pointer until a click.
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged].contains(event.type),
              let window = event.window, let view = window.contentView else { return false }
        let place: URL
        do { place = try ChatFileCopy.forDrag(data, of: file) } catch {
            store.setFileProblem(String(l10n: "This file did not drag out of the chat."), for: file.id)
            return false
        }
        store.setFileProblem(nil, for: file.id)
        let carried = NSPasteboardItem()
        carried.setString(place.absoluteString, forType: .fileURL)
        carried.setData(Data(), forType: marker)
        let item = NSDraggingItem(pasteboardWriter: carried)
        // The Mac's own picture of a file of this kind under the pointer, as a drag from Finder shows it.
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: NSWorkspace.shared.icon(forFile: place.path))
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        source.carried[ObjectIdentifier(session)] = place
        return true
    }

    /// The copy that each drag on its way carries, by its session: the end of one drag never takes another's copy.
    private var carried: [ObjectIdentifier: URL] = [:]

    /// Outside the app a copy, never a move; inside it nothing, so no view of the app takes the file.
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// A drag that nothing took leaves no copy behind.
    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        let key = ObjectIdentifier(session)
        MainActor.assumeIsolated {
            if let place = carried.removeValue(forKey: key), operation.isEmpty {
                try? FileManager.default.removeItem(at: place.deletingLastPathComponent())
            }
        }
    }

    /// The drag pasteboard holds one of the chat's own files. Read it only while a drag is over a view of the app,
    /// where that pasteboard is the drag's own: every drag writes it again as it begins.
    static var isOver: Bool { NSPasteboard(name: .drag).types?.contains(marker) == true }

    /// The place is one of the app's own copies of a chat's files.
    nonisolated static func isCopy(_ url: URL) -> Bool {
        let folder = ChatFileCopy.folder.resolvingSymlinksInPath().path + "/"
        return url.isFileURL && url.resolvingSymlinksInPath().path.hasPrefix(folder)
    }
}

/// The press on an agent's file that moves: the drag of the file out of the chat (`ChatFileDrag`), once for each press.
private struct DragsOut: ViewModifier {
    let store: FleetStore
    let file: MessageAttachment
    let begins: () -> Void
    @GestureState private var began = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4).updating($began) { _, began, _ in
                guard !began else { return }
                began = true
                if ChatFileDrag.begin(file, store: store) { begins() }
            }
        )
    }
}

/// **A file's row in a chat** (the owner, 20 November 2026, of the row under a message: "file does not breath", "no hint
/// taht I can preview the file either", and to its picture "also the eye is fine but I need a download icon/button
/// too!"): its kind's symbol in a tile, its name in the chat's size with its size under it, 12 points of room all round,
/// up to 380 points wide so the name keeps its room beside the buttons; under the pointer the hand and a lighter fill,
/// as a row that opens its detail. At its end, at rest, the eye, which opens the preview as a press on the row does,
/// and for an agent's file the save to Downloads: the app's icon buttons, muted on their rest fill, their words on hover.
struct FileRowLook: View {
    let name: String
    let symbol: String
    /// The size, or "Not loaded".
    let detail: String
    /// The hub has not given the bytes yet: the detail in orange.
    var late = false
    var hovered = false
    let open: () -> Void
    /// The save to Downloads, for an agent's file only; nil for his own files and a guidance's.
    var save: (() -> Void)? = nil
    var saveWords = ""
    var openWords = ""
    /// The save icon's accessibility identifier.
    var saveID = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.accent)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(ChatStyle.font).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                Text(detail).font(ChatStyle.detail).foregroundStyle(late ? Color.orange : FleetStyle.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                // Hidden from VoiceOver: the row's own press opens the file, and its Save to Downloads action saves it.
                IconButton(symbol: "eye", words: openWords, size: 12, side: IconMetrics.small, action: open)
                    .accessibilityHidden(true)
                if let save {
                    SaveFileIcon(words: saveWords, side: IconMetrics.small, onPicture: false, action: save)
                        .accessibilityIdentifier(saveID).accessibilityHidden(true)
                }
            }
        }
        .padding(12)
        // a little lighter under the pointer, as a row that opens its detail (`FleetRowButtonStyle`)
        .background(hovered ? Color(white: 0.23) : FleetStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        // the hand under the pointer, as a link shows it: a press on the row opens the file (a picture keeps the arrow)
        .pointerStyle(.link)
        .frame(maxWidth: 380, alignment: .leading)
    }
}

/// The save icon of an agent's file (the owner's yes of 18 November 2026): the Mac's own mark for a download, in a
/// round field of the page's surface, so it stands out on a picture of any colour.
private struct SaveFileIcon: View {
    /// "Save <name> to Downloads".
    let words: String
    var side: CGFloat = IconMetrics.side
    /// Over a picture: the text's colour in a round field of the page's surface. In a file's row: as the app's icon
    /// buttons, muted on their rest fill.
    var onPicture = true
    let action: () -> Void

    var body: some View {
        IconButton(symbol: "square.and.arrow.down", words: words, size: 12,
                   side: side, tint: onPicture ? FleetStyle.text : FleetStyle.muted) {
            // The second click of a double click is no second save: a save of bytes in memory ends before it comes.
            // Only the click asks; the accessibility action comes with no event of its own.
            if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1 {
                return
            }
            action()
        }
            .background(onPicture ? FleetStyle.surface : .clear, in: Circle())
            .environment(\.onCard, onPicture)
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
    /// The save icon at the picture's top right, while the pointer is on an agent's picture; nil otherwise.
    var save: (() -> Void)? = nil
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
        let data = wordsStand ? nil : store.heldBytes(of: file)
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
                    .overlay(alignment: .topTrailing) {
                        if let save {
                            SaveFileIcon(words: String(l10n: "Save \(file.name) to Downloads"), action: save)
                                .accessibilityIdentifier("save-file-\(file.id)").padding(6)
                        }
                    }
            } else {
                plate(data: data, failed: failed)
            }
        }
        // The picture at the top of its place, on the message's side; the plate fills the place. The place takes the room
        // it is given up to its own width, and never more.
        .frame(maxWidth: Self.place.width, minHeight: Self.place.height, maxHeight: Self.place.height,
               alignment: Alignment(horizontal: side, vertical: .top))
        // Read again when the hub answers again, so a picture that did not come while it was away comes by itself; after
        // a change of hub or database, which empties the store's files; and when this tile's number names another file.
        .task(id: "\(store.isFresh) \(store.filesGeneration) \(file.sha256)") { if store.isFresh { await read() } }
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
    store.setFileError(nil, for: composer)      // one batch, as a drop is
    switch pasted {
    case .files(let urls):
        for url in urls.prefix(MessageAttachment.perMessage) { await store.stage(contentsOf: url, for: composer) }
    case .picture(let data):
        guard let picture = try? MessageAttachment.imageForSending(data, shown: store.filesTaken(by: composer) == .shown)
        else {
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
                guard !AppFront.holdsKeys else { return false }     // no key after a front from outside (`AppFront`)
                // Cmd+V in the preview window over the app is that window's, never a file for the composer behind it.
                guard !event.inPreviewWindow else { return false }
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
    /// Over a task's page, the file goes into its guidance.
    var guidance = false

    var body: some View {
        RoundedRectangle(cornerRadius: FormMetrics.radius, style: .continuous)
            .strokeBorder(FleetStyle.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .padding(10)
            .overlay {
                Label(guidance ? "Add to this guidance" : "Add to this message", systemImage: "plus")
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
                // An agent's file dragged out of the chat goes where he drops it outside, never into his own message.
                // AppKit already refuses every place inside the app for that drag; this refuses it a second time, and
                // also a copy of the app's own folder dragged with no marker (the mark can show for that one: it does
                // not see the places that a drag carries).
                guard let composer, store.supportsAttachments, !ChatFileDrag.isOver,
                      !urls.contains(where: ChatFileDrag.isCopy) else { return false }
                // A drop is one batch: the words of a file that it refuses stay while the next file of it goes in.
                store.setFileError(nil, for: composer)
                Task { for url in urls.prefix(MessageAttachment.perMessage) {
                    await store.stage(contentsOf: url, for: composer)
                } }
                return true
            } isTargeted: { over = $0 && mark && composer != nil && store.supportsAttachments && !ChatFileDrag.isOver }
            .overlay { if over { DropMark(guidance: composer?.hasPrefix("task:") == true) } }
    }
}

extension View {
    /// Cmd+V stages a picture or a file in this composer (`PasteAttachments`); nil takes no file.
    func pasteAttachments(store: FleetStore, composer: String?) -> some View {
        modifier(PasteAttachments(store: store, composer: composer))
    }

    /// A drag of this file out of the chat (`ChatFileDrag`); nil drags nothing. `begins` runs as the drag begins: the
    /// pointer leaves the window with no exit that the view sees.
    @ViewBuilder func dragsOut(_ file: MessageAttachment?, store: FleetStore, begins: @escaping () -> Void) -> some View {
        if let file { modifier(DragsOut(store: store, file: file, begins: begins)) } else { self }
    }

    /// A file dropped here is staged in this composer (`StageDroppedFiles`); nil takes no file.
    func stageDroppedFiles(store: FleetStore, composer: String?, mark: Bool = false) -> some View {
        modifier(StageDroppedFiles(store: store, composer: composer, mark: mark))
    }
}

extension NSEvent {
    /// The key or click is the preview window's (Quick Look over the app): a watch of the app's keys leaves it alone,
    /// so Cmd+V there puts nothing into the composer behind it.
    var inPreviewWindow: Bool { window is QLPreviewPanel }
}
