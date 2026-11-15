import Foundation

/// **One JSON value, kept as it came.** The program passes the agent's fields to the hub and the hub's answer to the
/// agent without a type of its own for either, as `owner_mcp.py` does: a whole number stays a whole number, `true` stays
/// a boolean and `null` stays `null`, so the hub checks each field and not this program.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    /// A whole number that `Int64` cannot hold, as its digits. Python keeps such a number a whole number, and this
    /// program cannot, so a tool refuses it in the arguments (`OwnerTools.call`).
    case bigInt(String)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // ------------------------------------------------------------ reading

    /// The value of a JSON text, or nil when the text is no JSON. Read as Python's `json.loads` reads it: a number with
    /// no fraction and no exponent is a whole number (`.bigInt` when `Int64` cannot hold it), every other number is a
    /// float, also one at or above 2^64 (`JSONSerialization` gave such a float as a decimal with no fraction, which read
    /// as a whole number until 14 November 2026); `NaN`, `Infinity` and `-Infinity` are floats; the last of two equal
    /// keys counts; a control character inside a string is no JSON. A lone surrogate, which Python keeps and a Swift
    /// string cannot, becomes U+FFFD.
    public static func parse(_ data: Data) -> JSONValue? {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
        var reader = Reader(bytes: bytes)
        reader.space()
        guard let value = reader.value(depth: 0) else { return nil }
        reader.space()
        return reader.at == bytes.count ? value : nil
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    /// The reader of `parse`, over the bytes of a text that is valid UTF-8.
    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        /// Deeper than this is no JSON here: Python stops at its own limit of recursion.
        static let deepest = 512

        mutating func space() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        mutating func word(_ text: String) -> Bool {
            let wanted = Array(text.utf8)
            guard bytes.count - at >= wanted.count, Array(bytes[at..<at + wanted.count]) == wanted else { return false }
            at += wanted.count
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard at < bytes.count, depth < Self.deepest else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return word("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return word("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return word("null") ? .null : nil
            case UInt8(ascii: "N"): return word("NaN") ? .double(.nan) : nil
            case UInt8(ascii: "I"): return word("Infinity") ? .double(.infinity) : nil
            case UInt8(ascii: "-") where word("-Infinity"): return .double(-.infinity)
            default: return number()
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            at += 1
            var map: [String: JSONValue] = [:]
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(map) }
            while true {
                space()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = string() else { return nil }
                space()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                space()
                guard let item = value(depth: depth + 1) else { return nil }
                map[key] = item
                space()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(map) }
                return nil
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            at += 1
            var list: [JSONValue] = []
            space()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(list) }
            while true {
                space()
                guard let item = value(depth: depth + 1) else { return nil }
                list.append(item)
                space()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(list) }
                return nil
            }
        }

        mutating func hex4() -> UInt32? {
            guard bytes.count - at >= 4 else { return nil }
            var number: UInt32 = 0
            for byte in bytes[at..<at + 4] {
                guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { return nil }
                number = number * 16 + UInt32(digit)
            }
            at += 4
            return number
        }

        mutating func string() -> String? {
            at += 1
            var out: [UInt8] = []
            func add(_ scalar: UInt32) {
                out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
            }
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                switch byte {
                case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
                case 0..<0x20: return nil
                case UInt8(ascii: "\\"):
                    guard at < bytes.count else { return nil }
                    let escape = bytes[at]
                    at += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let unit = hex4() else { return nil }
                        if (0xD800..<0xDC00).contains(unit), bytes.count - at >= 6, bytes[at] == UInt8(ascii: "\\"),
                           bytes[at + 1] == UInt8(ascii: "u") {
                            let back = at
                            at += 2
                            if let low = hex4(), (0xDC00..<0xE000).contains(low) {
                                add(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                                continue
                            }
                            at = back
                        }
                        add((0xD800..<0xE000).contains(unit) ? 0xFFFD : unit)
                    default: return nil
                    }
                default: out.append(byte)
                }
            }
            return nil
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`, Python's own number of JSON.
        mutating func number() -> JSONValue? {
            let start = at
            func digits() -> Int {
                let from = at
                while at < bytes.count, (0x30...0x39).contains(bytes[at]) { at += 1 }
                return at - from
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count, (0x30...0x39).contains(bytes[at]) else { return nil }
            if bytes[at] == 0x30 { at += 1 } else { _ = digits() }
            var whole = true
            if at + 1 < bytes.count, bytes[at] == UInt8(ascii: "."), (0x30...0x39).contains(bytes[at + 1]) {
                at += 1
                _ = digits()
                whole = false
            }
            if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
                let back = at
                at += 1
                if at < bytes.count, bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+") { at += 1 }
                if digits() == 0 { at = back } else { whole = false }
            }
            let text = String(decoding: bytes[start..<at], as: UTF8.self)
            if whole {
                if let number = Int64(text) { return .int(number) }
                return .bigInt(text)
            }
            return Double(text).map(JSONValue.double)
        }
    }

    // ------------------------------------------------------------ what Python reads in it

    public subscript(key: String) -> JSONValue? {
        if case .object(let map) = self { return map[key] }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let map) = self { return map }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let list) = self { return list }
        return nil
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// The first whole number in this value that `Int64` cannot hold, or nil.
    public var tooBig: String? {
        switch self {
        case .bigInt(let digits): return digits
        case .array(let list): return list.lazy.compactMap(\.tooBig).first
        case .object(let map): return map.keys.sorted().lazy.compactMap { map[$0]!.tooBig }.first
        default: return nil
        }
    }

    /// Python's truth of the value: `None`, `False`, `0`, `""`, `[]` and `{}` are false.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .bigInt: return true
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.isEmpty
        }
    }

    /// Python's `str()` of the value, as `owner_mcp.py` puts a value in a path or a query: `True`, `None`, `5`.
    public var pythonText: String {
        switch self {
        case .null: return "None"
        case .bool(let value): return value ? "True" : "False"
        case .int(let value): return String(value)
        case .bigInt(let digits): return digits
        case .double(let value): return JSONValue.pythonFloat(value)
        case .string(let value): return value
        case .array, .object: return dumps()
        }
    }

    // ------------------------------------------------------------ writing, as Python's json.dumps writes

    /// The text of `json.dumps(value, indent=indent, sort_keys=True)` with Python's defaults: every character outside
    /// ASCII escaped, "," between items and ": " after a key when there is an indent, ", " and ": " when there is none.
    public func dumps(indent: Int? = nil) -> String {
        var out = ""
        write(into: &out, indent: indent, depth: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?, depth: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .bigInt(let digits): out += digits
        case .double(let value): out += JSONValue.pythonFloat(value)
        case .string(let value): JSONValue.quote(value, into: &out)
        case .array(let list):
            guard !list.isEmpty else { out += "[]"; return }
            out += "["
            for (place, item) in list.enumerated() {
                if place > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (depth + 1)) }
                item.write(into: &out, indent: indent, depth: depth + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * depth) }
            out += "]"
        case .object(let map):
            guard !map.isEmpty else { out += "{}"; return }
            out += "{"
            for (place, key) in map.keys.sorted(by: JSONValue.pythonOrder).enumerated() {
                if place > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (depth + 1)) }
                JSONValue.quote(key, into: &out)
                out += ": "
                map[key]!.write(into: &out, indent: indent, depth: depth + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * depth) }
            out += "}"
        }
    }

    /// Python sorts keys by their code points.
    static func pythonOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    /// A string as Python's `json.dumps` writes it with `ensure_ascii`.
    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += "\\u" + String(format: "%04x", unit)
            }
        }
        out += "\""
    }

    /// Python's `repr` of a float: the shortest text that reads back as the same number, as Swift's own.
    static func pythonFloat(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return "\(value)"
    }

}
