import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// One file that the owner sent with a message (owner feature `attachments`, UI-API.md 1.14). The hub keeps the bytes
/// outside its checkout, named by their SHA-256, and an app reads them on the owner route. Nothing is shown before the
/// size and the hash of what came back match what the hub said, as a checked task output is.
public struct MessageAttachment: Decodable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let mime: String
    public let size: Int
    public let sha256: String
    public let created: Double
    /// Owner feature `attachment_knowledge` (UI-API.md 1.30 and 1.31): the day the owner said to keep this file past
    /// the ninety days, or nil for one the hub still lets go with its message -- and nil from a hub before that
    /// feature, which kept none.
    public let kept: Kept?

    /// When he kept it, and the owner knowledge file it became. `knowledge` is nil for a file kept **alone**: what
    /// could not become text -- a screenshot, a mockup, a zip, a PDF -- whose only copy is the hub's own folder.
    public struct Kept: Decodable, Sendable, Equatable {
        public let at: Double
        public let knowledge: String?

        public init(at: Double, knowledge: String? = nil) {
            self.at = at
            self.knowledge = knowledge
        }
    }

    public init(id: Int, name: String, mime: String, size: Int, sha256: String, created: Double, kept: Kept? = nil) {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = size
        self.sha256 = sha256
        self.created = created
        self.kept = kept
    }

    /// The hub's own rules, so an app refuses a file before anything travels: what it takes, the extension that each
    /// type keeps, the size of one file, and how many go with one message.
    public static let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
                               "application/pdf": "pdf", "application/zip": "zip", "text/plain": "txt",
                               "text/markdown": "md", "text/csv": "csv", "application/json": "json"]
    public static let sizeLimit = 25 * 1024 * 1024
    public static let perMessage = 4
    /// The types that an agent's message can carry besides `types` (CHAT-APPS.md 20): an app reads and opens them.
    /// The owner sends them himself only to a hub with the feature `office_files` (`sendable`).
    public static let agentTypes = ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
                                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
                                    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx"]

    /// **Whether the owner can send a file of this type** to a hub: `types`, and with the hub's owner feature
    /// `office_files` (UI-API.md 1.251; the owner, 20 November 2026: "Yes, fix both") also Word, Excel and PowerPoint
    /// (`agentTypes`), which a hub before it refuses.
    public static func sendable(_ mime: String, office: Bool) -> Bool {
        types[mime] != nil || (office && agentTypes[mime] != nil)
    }

    /// The words of a file whose type the hub does not take, by what this hub takes (`sendable`).
    public static func typeWords(office: Bool) -> String {
        office ? String(l10n: "This hub takes images, PDF, ZIP, Word, Excel, PowerPoint, text, Markdown, CSV and JSON.")
               : AttachmentError.type.errorDescription ?? ""
    }

    /// **A file that a session with no shell can open**: a picture or a text, which the hub gives in the tool's answer
    /// itself (`t_read_attachment`). A session of an agent whose Shell box is off opens no other file of the owner's
    /// guidance (owner API 1.223), so its guidance box takes only these.
    public static func opensWithoutShell(_ mime: String) -> Bool {
        types[mime] != nil && (mime.hasPrefix("image/") || isText(mime))
    }

    /// A text that the hub gives in a tool's answer: its own check in `t_read_attachment`.
    public static func isText(_ mime: String) -> Bool {
        types[mime] != nil && (mime.hasPrefix("text/") || mime == "application/json")
    }

    /// **The largest picture that the hub gives in a tool's answer** (`hub.py` `ATTACH_SHOWN_BYTES` and
    /// `ATTACH_SHOWN_SIDE`): a larger one does not reach a session with no shell, so such a session's box makes each
    /// picture this small before it goes up (`imageForSending`).
    public static let shownPictureBytes = 3_750_000
    public static let shownPictureSide = 8000

    /// **The pictures that the apps draw from their bytes**: the four types whose first bytes the hub checks
    /// (`hub.py` `ATTACH_PICTURES`). A chat app's file of any other picture type (a TIFF, a DNG, a HEIC; CHAT-APPS.md
    /// 8.1, since 20 November 2026) is a file row, which the preview window opens in its own process at a click: no
    /// decoder in the app's own process ever reads a stranger's bytes of a type that nobody checked.
    public static let drawnPictureTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    public var isImage: Bool { Self.drawnPictureTypes.contains(mime) }

    /// The four types whose own words can become one of the owner's knowledge files in one press (`POST
    /// /ui/knowledge` `{attachment}`, UI-API.md 1.30), because knowledge is text that `search_knowledge` reads.
    /// Every other type the hub takes can only be kept as the file itself (UI-API.md 1.31).
    public static let knowledgeTypes: Set<String> = ["text/plain", "text/markdown", "text/csv", "application/json"]

    /// Whether the hub still holds this file past the ninety days because the owner said so.
    public var isKept: Bool { kept != nil }

    /// The owner knowledge file this one became, or nil: it became none, or it is not kept at all.
    public var keptAs: String? { kept?.knowledge }

    /// Whether `POST /ui/knowledge` `{attachment}` would take this file. The hub answers 415 for every other type.
    public var canBecomeKnowledge: Bool { Self.knowledgeTypes.contains(mime) }

    /// The type that the hub takes for this file name, or nil when it takes none. office: the hub has the feature
    /// `office_files` (`sendable`).
    public static func mime(forName name: String, office: Bool = false) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "jpeg" { return "image/jpeg" }
        if ext == "markdown" { return "text/markdown" }
        return types.first { $0.value == ext }?.key ?? (office ? agentTypes.first { $0.value == ext }?.key : nil)
    }

    /// A name that travels in a header and in a `Content-Disposition`: ASCII letters, digits, . _ - and spaces,
    /// never a path. It is the hub's own rule, step by step, so the name that comes back is the name that went.
    public static func safeName(_ name: String, mime: String) -> String {
        let keep = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._- ")
        var cleaned = String(name.map { keep.contains($0) ? $0 : "_" }).trimmingCharacters(in: .whitespaces)
        let lead = cleaned.prefix { $0 == "." || $0 == "-" }.count
        if lead > 0 { cleaned = "_" + cleaned.dropFirst(lead) }
        cleaned = String(cleaned.prefix(80))
        // a type of no table: a chat app's file (CHAT-APPS.md 8.1) keeps its own extension, which the preview window
        // reads to open it
        guard let known = types[mime] ?? agentTypes[mime] else { return cleaned.isEmpty ? "file" : cleaned }
        let ext = "." + known
        return cleaned.lowercased().hasSuffix(ext) ? cleaned : (cleaned.isEmpty ? "file" : cleaned) + ext
    }

    /// Whether `mime` is a type as the hub keeps one: `type/subtype` in lower case, each part 1 to 127 of the letters,
    /// digits and `!#$&^_.+-` that a type token may hold, which is all that the hub lets through (`hub.py`
    /// `MIME_TOKEN`). Since chat apps' files of any type come (CHAT-APPS.md 8.1), any such type is a file that the
    /// apps open and save.
    public static func isTypeToken(_ mime: String) -> Bool {
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        return parts.count == 2 && parts.allSatisfy { part in
            (1...127).contains(part.count) && part.allSatisfy { allowed.contains($0) } &&
                part.first.map { $0.isLetter || $0.isNumber } == true
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the hub said about this file is a file that an app may ask for.
    public func validate() throws {
        guard id > 0, !name.isEmpty, name.utf8.count <= 200, Self.isTypeToken(mime),
              size > 0, size <= Self.sizeLimit, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }), created > 0,
              kept.map({ $0.at > 0 && $0.knowledge?.isEmpty != true }) != false
        else { throw AttachmentError.metadata }
    }

    /// These bytes are the file that the hub named: the same count and the same SHA-256.
    public func matches(_ data: Data) -> Bool {
        data.count == size && Self.digest(data) == sha256
    }

    /// The size in the owner's words.
    public var sizeWords: String { Self.sizeWords(size) }

    /// Its number as his Mac writes numbers (review B13, fix round 2): "%.1f" put a point where his locale puts a comma.
    public static func sizeWords(_ size: Int) -> String {
        size < 1024 ? "\(size.formatted()) B"
            : size < 1024 * 1024 ? "\((size / 1024).formatted()) KB"
            : (Double(size) / (1024 * 1024)).formatted(.number.precision(.fractionLength(1))) + " MB"
    }

    /// The symbol that stands for this file where no picture is shown.
    public var symbol: String {
        switch mime {
        case let m where m.hasPrefix("image/"): "photo"
        case "application/pdf": "doc.richtext"
        case "application/zip": "doc.zipper"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "tablecells"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": "rectangle.on.rectangle"
        default: "doc.text"
        }
    }
}

/// Pictures, for the apps that show and send them. ImageIO draws a small copy without holding the whole picture in
/// memory, and it writes JPEG, so neither app needs AppKit or UIKit for this.
extension MessageAttachment {
    /// A small picture of these bytes, at most `maxPixels` on its longest side. nil when the bytes are no picture.
    public static func thumbnail(_ data: Data, maxPixels: Int = 320, decodeImmediately: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: decodeImmediately,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }

    /// The bytes that an app sends for a picture that the owner picked. PNG and a small JPEG go as they are; every
    /// other picture (a photo of an iPhone is HEIC) becomes JPEG, and a very large one is made smaller first, so a
    /// message from a phone is quick and the hub's limit holds.
    /// `shown`: for a session with no shell, which gets a picture only up to `shownPictureBytes` and
    /// `shownPictureSide`; a larger PNG or JPEG is made smaller here, as every other kind of picture is.
    public static func imageForSending(_ data: Data, maxPixels: Int = 2048, shown: Bool = false) throws
        -> (data: Data, mime: String) {
        guard !data.isEmpty else { throw AttachmentError.bytes }
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        let fits = !shown || (data.count <= shownPictureBytes && source.map { pictureSide($0) <= shownPictureSide } == true)
        if fits, data.starts(with: [0x89, 0x50, 0x4E, 0x47]), data.count <= sizeLimit { return (data, "image/png") }
        if fits, data.starts(with: [0xFF, 0xD8, 0xFF]), data.count <= 4 * 1024 * 1024 { return (data, "image/jpeg") }
        guard let source,
              let smaller = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        else { throw AttachmentError.type }
        let made = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(made, "public.jpeg" as CFString, 1, nil) else {
            throw AttachmentError.type
        }
        CGImageDestinationAddImage(out, smaller, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(out), made.length > 0, made.length <= (shown ? shownPictureBytes : sizeLimit) else {
            throw AttachmentError.tooLarge
        }
        return (made as Data, "image/jpeg")
    }

    /// The longer side of a picture in pixels, or `Int.max` when the file does not say it.
    private static func pictureSide(_ source: CGImageSource) -> Int {
        guard let facts = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = facts[kCGImagePropertyPixelWidth] as? Int, let height = facts[kCGImagePropertyPixelHeight] as? Int
        else { return .max }
        return max(width, height)
    }
}

/// A file of a message as a file of this Mac: for the preview window, for a drag to Finder and for the save icon of an
/// agent's file (the owner's yes of 18 November 2026).
extension MessageAttachment {
    /// The name as one file of a folder: a slash, a colon or a NUL becomes "_", an invisible format or control character
    /// (a right-to-left override) goes, a name that begins with a dot gets a "_" in front, and an empty name is "file".
    /// So the name never leaves its folder, never hides its file and never shows another extension than its own. It
    /// reads each code point: as a Character, a slash with an accent mark on it is no slash.
    public static func diskName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format, .control, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append("/:".unicodeScalars.contains(scalar) ? "_" : scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "file" }
        // The first code point, not the first Character: a dot with an accent mark on it still hides the file.
        return cleaned.unicodeScalars.first == "." ? "_" + cleaned : cleaned
    }

    /// Writes the bytes into `folder` under the file's own name, or as a browser saves a download, with " 2", " 3" …
    /// before the extension when that name is taken: a file that is in the folder already is never replaced. Gives
    /// the place that it wrote.
    public static func save(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let whole = diskName(name)
        let ext = (whole as NSString).pathExtension, stem = (whole as NSString).deletingPathExtension
        for count in 1...1000 {
            let next = count == 1 ? whole : ext.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(ext)"
            let place = folder.appendingPathComponent(next, isDirectory: false)
            do {
                try data.write(to: place, options: .withoutOverwriting)
                return place
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

public enum AttachmentError: LocalizedError {
    case metadata, bytes, tooLarge, type

    public var errorDescription: String? {
        switch self {
        case .metadata: String(l10n: "The hub described this file in a way this app does not take.")
        case .bytes: String(l10n: "The file that came back is not the file that the hub named.")
        case .tooLarge: String(l10n: "A file is at most 25 MB.")
        case .type: String(l10n: "This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON.")
        }
    }
}
