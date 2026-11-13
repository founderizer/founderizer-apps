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

    public var isImage: Bool { mime.hasPrefix("image/") }

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

    /// The type that the hub takes for this file name, or nil when it takes none.
    public static func mime(forName name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "jpeg" { return "image/jpeg" }
        if ext == "markdown" { return "text/markdown" }
        return types.first { $0.value == ext }?.key
    }

    /// A name that travels in a header and in a `Content-Disposition`: ASCII letters, digits, . _ - and spaces,
    /// never a path. It is the hub's own rule, step by step, so the name that comes back is the name that went.
    public static func safeName(_ name: String, mime: String) -> String {
        let keep = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._- ")
        var cleaned = String(name.map { keep.contains($0) ? $0 : "_" }).trimmingCharacters(in: .whitespaces)
        let lead = cleaned.prefix { $0 == "." || $0 == "-" }.count
        if lead > 0 { cleaned = "_" + cleaned.dropFirst(lead) }
        cleaned = String(cleaned.prefix(80))
        let ext = "." + (types[mime] ?? "bin")
        return cleaned.lowercased().hasSuffix(ext) ? cleaned : (cleaned.isEmpty ? "file" : cleaned) + ext
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the hub said about this file is a file that an app may ask for.
    public func validate() throws {
        guard id > 0, !name.isEmpty, name.utf8.count <= 200, Self.types[mime] != nil,
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
        default: "doc.text"
        }
    }
}

/// Pictures, for the apps that show and send them. ImageIO draws a small copy without holding the whole picture in
/// memory, and it writes JPEG, so neither app needs AppKit or UIKit for this.
extension MessageAttachment {
    /// A small picture of these bytes, at most `maxPixels` on its longest side. nil when the bytes are no picture.
    public static func thumbnail(_ data: Data, maxPixels: Int = 320) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }

    /// The bytes that an app sends for a picture that the owner picked. PNG and a small JPEG go as they are; every
    /// other picture (a photo of an iPhone is HEIC) becomes JPEG, and a very large one is made smaller first, so a
    /// message from a phone is quick and the hub's limit holds.
    public static func imageForSending(_ data: Data, maxPixels: Int = 2048) throws -> (data: Data, mime: String) {
        guard !data.isEmpty else { throw AttachmentError.bytes }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]), data.count <= sizeLimit { return (data, "image/png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]), data.count <= 4 * 1024 * 1024 { return (data, "image/jpeg") }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
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
        guard CGImageDestinationFinalize(out), made.length > 0, made.length <= sizeLimit else {
            throw AttachmentError.tooLarge
        }
        return (made as Data, "image/jpeg")
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
