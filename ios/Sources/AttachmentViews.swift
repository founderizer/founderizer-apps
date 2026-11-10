import FleetCore
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The "+" of a composer: the owner picks pictures from the library or a file from Files (owner feature
/// `attachments`). What comes back goes to the store, which writes the bytes on this phone before anything travels.
struct AttachmentButton: View {
    let store: MobileStore
    /// The composer that the files belong to: one chat, or one open item of Needs you.
    let composer: String
    /// A plain "+" with its 44-point touch, as it stands inside a chat's glass composer (D-6); a round button beside
    /// an answer's field otherwise.
    var bare = false
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 30

    /// How many more files this message may carry.
    private var room: Int { max(0, MessageAttachment.perMessage - store.stagedFiles(for: composer).count) }

    var body: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Files", systemImage: "folder") { pickingFiles = true }
        } label: {
            if bare {
                // Two thirds of the round one's size, so it grows with the text as far as the composer lets it: it
                // stood at 20 points beside the text of the largest sizes.
                Image(systemName: "plus")
                    .font(.system(size: size * 2 / 3, weight: .medium))
                    .foregroundStyle(room > 0 ? Brand.muted : Color(.tertiaryLabel))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                // A 44-point touch around the 30-point circle, as Send has; the composer keeps the circle's size.
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: size))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(room > 0 ? Color.secondary : Color(.tertiaryLabel))
                    .frame(width: max(44, size), height: max(44, size))
                    .contentShape(Rectangle())
            }
        }
        .padding(bare ? 0 : -(max(44, size) - size) / 2)
        .disabled(room == 0 || store.storageError != nil)
        // **Every part of it named for VoiceOver** (fix round 2, item 56): the system's menu put a second, unnamed
        // button inside "Add a file" on every composer and answer box. VoiceOver reads the same menu, by its words.
        // **One name** (fix round 3, HIG): the menu read "Add a file, Photos". The button is "Add a file", and its two
        // ways are its actions.
        .accessibilityRepresentation {
            Button("Add a file") { pickingPhotos = true }
                .accessibilityActions {
                    Button("Photos") { pickingPhotos = true }
                    Button("Files") { pickingFiles = true }
                }
        }
        .accessibilityIdentifier("add-file")
        .photosPicker(isPresented: $pickingPhotos, selection: $picked, maxSelectionCount: room, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await takePhotos(items) }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: Self.fileTypes,
                      allowsMultipleSelection: true) { result in
            Task { await takeFiles(result) }
        }
    }

    /// The types that the hub takes, as the Files picker names them.
    private static let fileTypes: [UTType] = [.png, .jpeg, .gif, .webP, .pdf, .zip, .plainText, .commaSeparatedText,
                                              .json, UTType(filenameExtension: "md") ?? .plainText]

    /// A picture from the library. An iPhone photo is HEIC and a photo is large, so the bytes become a JPEG of a size
    /// that travels well; a PNG (a screenshot) goes as it is.
    private func takePhotos(_ items: [PhotosPickerItem]) async {
        for item in items.prefix(room) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    store.fileFailed("That picture did not open.")
                    continue
                }
                let picture = try MessageAttachment.imageForSending(data)
                let name = item.itemIdentifier.map { "photo-\(String($0.prefix(8))).\(picture.mime == "image/png" ? "png" : "jpg")" }
                    ?? "photo.\(picture.mime == "image/png" ? "png" : "jpg")"
                await store.stage(picture.data, name: name, mime: picture.mime, for: composer)
            } catch {
                store.fileFailed((error as? LocalizedError)?.errorDescription ?? "That picture did not open.")
            }
        }
    }

    /// A file from Files. The picker gives a place outside this app, so the bytes are read while that place is open
    /// and nothing else is kept.
    private func takeFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                store.fileFailed("That file did not open.", detail: error.localizedDescription)
            }
            return
        }
        for url in urls.prefix(room) {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            guard let mime = MessageAttachment.mime(forName: url.lastPathComponent) else {
                store.fileFailed(AttachmentError.type.errorDescription)
                continue
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                store.fileFailed("That file did not open.")
                continue
            }
            if mime.hasPrefix("image/"), let picture = try? MessageAttachment.imageForSending(data) {
                await store.stage(picture.data, name: url.lastPathComponent, mime: picture.mime, for: composer)
            } else {
                await store.stage(data, name: url.lastPathComponent, mime: mime, for: composer)
            }
        }
    }
}

/// The files that wait in one composer: a picture shows itself, another file its kind. Each one says when it is
/// going up or did not go, and the x takes it out again.
struct AttachmentStrip: View {
    let store: MobileStore
    let composer: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 54
    /// nil: the files that still wait in the composer. A list of numbers: only those files, as a message that is on
    /// its way shows them, and none of them can be taken out any more.
    var sending: [Int]?
    /// The records of files that the hub took and that left the composer, which the row draws until its item folds.
    var held: [MobileStore.StagedFile]?

    private var files: [MobileStore.StagedFile] {
        if let held { return held }
        let onItsWay = store.pending?.attachments ?? []
        return store.stagedFiles(for: composer).filter { file in
            guard let id = file.attachmentID else { return sending == nil }
            return sending.map { $0.contains(id) } ?? !onItsWay.contains(id)
        }
    }

    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(files) { chip($0) }
                }
                .padding(.top, 8)
            }
            .scrollClipDisabled()
        }
    }

    private func chip(_ file: MobileStore.StagedFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                StagedPicture(store: store, file: file, side: side)
                if sending == nil {
                    // A 44-point touch around the 17-point mark, which keeps its place in the picture's corner.
                    Button {
                        store.removeStaged(file, for: composer)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-13.5)
                    .padding(3)
                    .accessibilityLabel("Take \(file.name) out")
                }
            }
            Text(file.failure == nil ? file.name : "Not sent")
                .font(.caption2).foregroundStyle(file.failure == nil ? Brand.muted : Brand.warning)
                .lineLimit(1).truncationMode(.middle).frame(width: side, alignment: .leading)
        }
        .accessibilityIdentifier("staged-\(file.name)")
    }
}

/// One staged file as a 54-point square: the picture itself, or the symbol of its kind, with a mark while it goes up
/// and a Retry when it did not.
private struct StagedPicture: View {
    let store: MobileStore
    let file: MobileStore.StagedFile
    let side: CGFloat
    @State private var picture: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.bubble)
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                    .font(.title3).foregroundStyle(.secondary)
            }
            if store.uploading.contains(file.requestID) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.45))
                ProgressView().controlSize(.small).tint(.white)
            } else if file.failure != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.45))
                Button {
                    guard let composer = store.composerOf(file) else { return }
                    Task { await store.upload(file, for: composer) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 17)).foregroundStyle(Brand.warning)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send \(file.name) again")
            }
        }
        .frame(width: side, height: side)
        .task(id: file.requestID) { picture = store.stagedThumbnail(file) }
    }
}

/// **A picture has its slot from the first frame, and keeps it** (T-34): its size is decided once, when the tile
/// first draws. A picture this phone already holds takes its own shape with the box's area, so a tall screenshot
/// stands as tall as a wide picture is wide: in the 240 × 150 box it was 91 points wide, 2.7 times narrower than the
/// grey box around it. A picture that is still on its way has the 240 × 150 box and is fitted into it when its bytes
/// come, so nothing around it moves. The hub does not send a picture's size; with it, every slot would take the
/// picture's shape from the first frame.
private struct PictureTile: View {
    let store: MobileStore
    let file: MessageAttachment
    @State private var slot: CGSize

    init(store: MobileStore, file: MessageAttachment) {
        self.store = store
        self.file = file
        _slot = State(initialValue: Self.slot(for: store.picture(file.id)))
    }

    /// The chat's box for a picture whose shape is not known.
    static let box = CGSize(width: 240, height: 150)
    /// The tallest a picture stands.
    static let tallest: CGFloat = 280

    /// The picture's own shape with the box's area, no wider than the box and no taller than `tallest`.
    static func slot(for picture: CGImage?) -> CGSize {
        guard let picture, picture.width > 0, picture.height > 0 else { return box }
        let ratio = CGFloat(picture.width) / CGFloat(picture.height)
        var width = (box.width * box.height * ratio).squareRoot()
        var height = width / ratio
        if width > box.width { width = box.width; height = width / ratio }
        if height > tallest { height = tallest; width = height * ratio }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    var body: some View {
        ZStack {
            Brand.bubble
            if let picture = store.picture(file.id) {
                Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                // **Until it comes, the grey plate and the photo mark; "Reading…" only after a second** (fix round 3,
                // item 45, as the Mac's tile). **The words' room is kept from the first frame** (T-34, fix round
                // 3d), so the mark stands where it will stand: it slid 8 points up when the words came.
                VStack(spacing: 6) {
                    Image(systemName: file.symbol).font(.title3).foregroundStyle(.secondary)
                    ZStack {
                        Text("Reading…").font(.footnote).hidden()
                        Held { Text("Reading…").font(.footnote).foregroundStyle(Brand.muted) }
                    }
                }
            }
        }
        .frame(width: slot.width, height: slot.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { if store.picture(file.id) == nil { await store.load(file) } }
    }
}

/// The files of one message, under its text: a picture is shown, another file is a row with its kind, its name and
/// its size. A tap opens it in the system's own viewer, from bytes whose SHA-256 the app checked.
struct AttachmentGallery: View {
    /// **A file's size, ≥ 5:1 on his dark bubble** (fix round 3, item 30): the quiet colour read 4.72:1 on #303030 there.
    static let sizeInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark && traits.accessibilityContrast != .high
            ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
            : UIColor(named: "BrandMuted", in: nil, compatibleWith: traits) ?? .secondaryLabel
    })

    let store: MobileStore
    let files: [MessageAttachment]
    var alignment: HorizontalAlignment = .trailing
    @State private var opened: URL?

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(files) { file in
                if file.isImage && store.notLoaded.contains(file.id) {
                    notLoaded(file)
                } else {
                    Button { open(file) } label: { item(file) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(file.name), \(file.sizeWords)")
                        .accessibilityIdentifier("file-\(file.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .quickLookPreview($opened)
    }

    @ViewBuilder private func item(_ file: MessageAttachment) -> some View {
        if file.isImage {
            PictureTile(store: store, file: file)
        } else {
            HStack(spacing: 10) {
                Image(systemName: file.symbol).font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.subheadline)
                        .lineLimit(1).truncationMode(.middle)
                    Text(file.sizeWords)
                        .font(.caption).foregroundStyle(Self.sizeInk)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Brand.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // On the gallery's side (margins pass, fault 1): under his bubble the row stood at the left of its
            // 240 points and stopped 40.7 points before the bubble's right edge, where his pictures end.
            .frame(maxWidth: 240, alignment: alignment == .trailing ? .trailing : .leading)
            .task { await store.load(file) }
        }
    }

    /// **A picture that did not come says so on its tile, with a ↻ that reads it again** (the owner's yes of 28
    /// October 2026 to D-7). The tile keeps its place and its size, so nothing moves when the picture comes; it said
    /// nothing and drew the kind's symbol for ever, and the reason stood under the composer.
    private func notLoaded(_ file: MessageAttachment) -> some View {
        ZStack {
            Brand.bubble
            // Its name and "Not loaded" (fix round 3, item 45); after ↻ the tile reads again, quiet for a second.
            VStack(spacing: 4) {
                Text(file.name).font(.footnote).lineLimit(1).truncationMode(.middle).padding(.horizontal, 40)
                Text("Not loaded").font(.footnote).foregroundStyle(Brand.warning)
            }
        }
        .frame(width: PictureTile.box.width, height: PictureTile.box.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // A 28-point circle with the platform's 44-point touch around it.
            Button { Task { await store.readAgain(file) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 28, height: 28)
                    .background(Brand.surface, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Read \(file.name) again")
            .accessibilityIdentifier("reload-\(file.id)")
        }
    }

    /// The system's viewer opens a file, never an address: the bytes come from the hub, checked, and are written
    /// where only this app can read them.
    private func open(_ file: MessageAttachment) {
        Task {
            await store.load(file)
            guard let data = store.fileData[file.id] else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
            let place = folder.appendingPathComponent("\(file.id)-\(file.name)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: place, options: [.atomic, .completeFileProtection])
                opened = place
            } catch { store.fileFailed("This file did not open on the phone.", detail: error.localizedDescription) }
        }
    }
}
