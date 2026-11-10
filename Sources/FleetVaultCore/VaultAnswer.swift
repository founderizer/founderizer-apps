import Foundation

/// What an agent gets of the answer of a request (`request`): its status and its text, without a protected value of
/// the login. The rule for the values is the vault's existing one (`VaultLogin.protectedValues`): a value of fewer
/// than 8 characters is used, is not looked for and is not called masked.
enum VaultAnswer {
    /// The protected values of the login as they are: what an answer must not show. `basic`: the Basic value that the
    /// request sent. It holds the password, so it is protected when the password is. A JSON answer can give a value in
    /// other forms (`\/`, `é`). They are not forms here: `reply` resolves the escapes of the answer.
    static func forms(of login: VaultLogin, basic: String? = nil) -> [Data] {
        var values = login.protectedValues.map(\.value)
        if let basic, login.protectedValues.contains(where: { $0.kind == "password" }) { values.append(basic) }
        return values.reduce(into: [Data]()) { forms, value in
            if !value.isEmpty, !forms.contains(Data(value.utf8)) { forms.append(Data(value.utf8)) }
        }
    }

    /// The first bytes of an answer that the vault keeps: the part that can be shown, and enough after it that a value
    /// which begins in that part is whole in what is kept. One byte of a value is at most six bytes of an answer: an
    /// ASCII character as `\uXXXX`. Each longer character has fewer bytes of an answer for each of its bytes.
    static func keep(for forms: [Data]) -> Int { VaultCall.maxBody + max(1, 6 * (forms.map(\.count).max() ?? 0)) - 1 }

    /// The HTTP status in the child's note, or nil. The last line of the note is `fleet ` and the three digits of a
    /// status from 100 to 599, byte for byte as curl writes it. The lines before it are not read.
    static func status(in note: Data) -> Int? {
        var line = note.last == 0x0a ? note.dropLast() : note
        if let end = line.lastIndex(of: 0x0a) { line = line[(end + 1)...] }
        guard let status = Int(String(decoding: line.suffix(3), as: UTF8.self)), (100...599).contains(status),
              line.elementsEqual("fleet \(status)".utf8) else { return nil }
        return status
    }

    /// The reply of a completed request. `kept`: the first `keep(for:)` bytes of the body; `total`: the count of all
    /// its bytes. At most the first `VaultCall.maxBody` bytes are shown. A body with a value that begins in them is
    /// not shown at all (`withheld: key`), so a cut never shows the first part of a protected value. The value can be
    /// as it is, or in a form that a JSON answer gives it. A body that is not text is not shown (`withheld: binary`).
    static func reply(job: Int, status: Int, kept: Data, total: Int, forms: [Data]) -> [String: Any] {
        func withheld(_ why: String) -> [String: Any] { ["ok": true, "v": 2, "job": job, "status": status, "withheld": why] }
        // The end of a `kept` that is not the whole body can be inside a value, so its last bytes are never shown.
        // From `keep(for:)` bytes, that leaves the first `maxBody` bytes.
        var shown = (total > kept.count ? kept.dropLast(keep(for: forms) - VaultCall.maxBody) : kept).prefix(VaultCall.maxBody)
        // A value that begins after that part is not shown, and it does not change the reply. Thus the reply does not
        // tell the length of a value.
        let plain = unescaped(kept, split: shown.count)
        func begins(_ form: Data, in bytes: Data, before end: Int) -> Bool { bytes.range(of: form).map { $0.lowerBound < end } == true }
        guard !forms.contains(where: { begins($0, in: kept, before: shown.endIndex) || begins($0, in: plain.text, before: plain.split) }) else {
            return withheld("key")
        }
        let truncated = total > shown.count
        // A cut can be inside one character: the bytes that begin it go, and no other byte.
        if truncated { shown = shown.dropLast(cutCharacter(in: shown)) }
        // The text is the bytes as they are: `String(data:encoding:)` is not byte for byte, because it drops a
        // byte order mark at the start of the body, and the reply would then say `truncated: false` for a body of
        // which it shows three bytes fewer.
        guard let text = String(validating: shown, as: UTF8.self) else { return withheld("binary") }
        let reply: [String: Any] = ["ok": true, "v": 2, "job": job, "status": status, "body": text, "truncated": truncated]
        // As for a sign-in: the encoded reply has no protected value.
        guard let encoded = try? JSONSerialization.data(withJSONObject: reply), !forms.contains(where: { encoded.range(of: $0) != nil }) else {
            return withheld("key")
        }
        return reply
    }

    /// `data` with its JSON string escapes resolved, one time: `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, and
    /// `\uXXXX` as UTF-8, with a high and a low surrogate together as one character. Bytes that are not a complete
    /// valid escape stay as they are. `split`: a count of bytes of `data`. The second result is the count of bytes of
    /// the text that come from the bytes and the escapes which begin in those first bytes.
    static func unescaped(_ data: Data, split: Int = 0) -> (text: Data, split: Int) {
        let bytes = [UInt8](data)
        /// The code unit of a `\uXXXX` at `place`, or nil.
        func unit(at place: Int) -> UInt32? {
            guard place + 6 <= bytes.count, bytes[place] == 0x5c, bytes[place + 1] == 0x75 else { return nil }
            var unit: UInt32 = 0
            for byte in bytes[(place + 2)..<(place + 6)] {
                guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { return nil }
                unit = unit << 4 | UInt32(digit)
            }
            return unit
        }
        var text: [UInt8] = [], index = 0, mark: Int?
        text.reserveCapacity(bytes.count)
        while index < bytes.count {
            if mark == nil, index >= split { mark = text.count }
            guard bytes[index] == 0x5c else { text.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count, let byte = short[bytes[index + 1]] {
                text.append(byte); index += 2
            } else if let unit = unit(at: index), let scalar = Unicode.Scalar(unit) {
                text.append(contentsOf: String(scalar).utf8); index += 6
            } else if let high = unit(at: index), high < 0xdc00, let low = unit(at: index + 6), (0xdc00...0xdfff).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)) {
                text.append(contentsOf: String(scalar).utf8); index += 12
            } else {
                text.append(0x5c); index += 1
            }
        }
        return (Data(text), mark ?? text.count)
    }

    /// The byte after `\` in each escape of two bytes, and the byte that the escape gives.
    private static let short: [UInt8: UInt8] = [0x22: 0x22, 0x5c: 0x5c, 0x2f: 0x2f, 0x62: 0x08, 0x66: 0x0c, 0x6e: 0x0a, 0x72: 0x0d, 0x74: 0x09]

    /// The count of the last bytes of `text` that begin one UTF-8 character and do not end it: 0 to 3. A cut inside a
    /// character leaves such bytes. Bytes that cannot begin a character are not counted.
    static func cutCharacter(in text: Data) -> Int {
        guard let start = text.suffix(3).lastIndex(where: { $0 & 0xc0 != 0x80 }) else { return 0 }
        let first = text[start], held = text.endIndex - start
        // For a first byte (Unicode, table 3-7): the count of bytes of its character, and what its next byte can be.
        let count = !(0xc2...0xf4).contains(first) ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4
        let next: ClosedRange<UInt8> = first == 0xe0 ? 0xa0...0xbf : first == 0xed ? 0x80...0x9f : first == 0xf0 ? 0x90...0xbf
            : first == 0xf4 ? 0x80...0x8f : 0x80...0xbf
        return held < count && (held == 1 || next.contains(text[start + 1])) ? held : 0
    }
}
