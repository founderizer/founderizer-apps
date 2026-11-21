import Foundation

/// **A whole number of a few hundred bytes, for one sum: `base ^ exponent mod modulus`** (the Diffie-Hellman step of a
/// Mac's screen sign-in, `RFBAppleSignIn`). Its limbs are 32 bits, least significant first. The power uses Montgomery's
/// method, so the modulus must be odd, as a Diffie-Hellman prime is. Nothing else of big-number arithmetic is here.
struct RFBNumber: Equatable {
    /// Least significant limb first, with no zero limbs at the top (zero is `[]`).
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    /// The number that these bytes write, most significant byte first (the wire's order).
    init(bigEndian bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4))
        }
        self.init(limbs: limbs)
    }

    var isZero: Bool { limbs.isEmpty }

    /// Writes zeros over the limbs of a secret number once it is used.
    mutating func wipe() {
        for index in limbs.indices { limbs[index] = 0 }
        limbs = []
    }

    /// The number's size in bits.
    var bits: Int { bitCount }

    static func < (a: RFBNumber, b: RFBNumber) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for index in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index]
        }
        return false
    }

    /// `self − 1`, for a number above zero.
    var lessOne: RFBNumber {
        var out = limbs
        for index in out.indices {
            if out[index] > 0 { out[index] -= 1; break }
            out[index] = UInt32.max
        }
        return RFBNumber(limbs: out)
    }

    /// The number in exactly `count` bytes, most significant first, zeros in front; nil when it needs more.
    func bigEndian(count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        for (index, limb) in limbs.enumerated() {
            for shift in 0..<4 {
                let byte = UInt8(truncatingIfNeeded: limb >> (8 * UInt32(shift)))
                let at = count - 1 - (index * 4 + shift)
                if at < 0 {
                    if byte != 0 { return nil }
                } else {
                    bytes[at] = byte
                }
            }
        }
        return bytes
    }

    private mutating func trim() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    private var bitCount: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private func bit(_ index: Int) -> Bool {
        let limb = index / 32
        return limb < limbs.count && (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    /// `self ^ exponent mod modulus`; nil for an even or a zero modulus.
    func power(_ exponent: RFBNumber, modulus: RFBNumber) -> RFBNumber? {
        guard let montgomery = Montgomery(modulus: modulus) else { return nil }
        return montgomery.power(self, exponent)
    }

    /// The sums of Montgomery's method for one odd modulus of `k` limbs: numbers in it are `k` limbs, below the modulus.
    private struct Montgomery {
        let modulus: [UInt32]
        let k: Int
        /// `-modulus⁻¹ mod 2³²`.
        let inverse: UInt32
        /// `R² mod modulus`, with `R = 2^(32k)`.
        let rSquared: [UInt32]

        init?(modulus number: RFBNumber) {
            guard let low = number.limbs.first, low & 1 == 1 else { return nil }
            modulus = number.limbs
            k = number.limbs.count
            // Newton's iteration doubles the correct low bits at each step: 1 → 2 → 4 → 8 → 16 → 32.
            var x: UInt32 = 1
            for _ in 0..<5 { x = x &* (2 &- low &* x) }
            inverse = 0 &- x
            // R² mod n by doubling 1, 2·32k times, each time back under n.
            var value = [UInt32](repeating: 0, count: number.limbs.count)
            value[0] = 1
            for _ in 0..<(2 * 32 * number.limbs.count) {
                value = Montgomery.doubled(value, below: number.limbs)
            }
            rSquared = value
        }

        /// `2·value mod n`, for a value below n.
        private static func doubled(_ value: [UInt32], below n: [UInt32]) -> [UInt32] {
            var out = [UInt32](repeating: 0, count: value.count)
            var carry: UInt32 = 0
            for index in 0..<value.count {
                out[index] = (value[index] << 1) | carry
                carry = value[index] >> 31
            }
            if carry == 1 || !less(out, n) { out = subtract(out, n) }
            return out
        }

        static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
            for index in stride(from: a.count - 1, through: 0, by: -1) where a[index] != b[index] {
                return a[index] < b[index]
            }
            return false
        }

        /// `a − b` in the width of a (wrapping above it), for limbs of the same count.
        static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var out = [UInt32](repeating: 0, count: a.count)
            var borrow: UInt64 = 0
            for index in 0..<a.count {
                let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
                out[index] = UInt32(truncatingIfNeeded: difference)
                borrow = (difference >> 63) & 1
            }
            return out
        }

        /// `a · b · R⁻¹ mod n` (CIOS), for a and b below n.
        func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: k + 2)
            for i in 0..<k {
                var carry: UInt64 = 0
                for j in 0..<k {
                    let sum = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + carry
                    t[j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                var sum = UInt64(t[k]) + carry
                t[k] = UInt32(truncatingIfNeeded: sum)
                t[k + 1] = UInt32(truncatingIfNeeded: sum >> 32)
                let m = t[0] &* inverse
                sum = UInt64(t[0]) + UInt64(m) * UInt64(modulus[0])
                carry = sum >> 32
                for j in 1..<k {
                    sum = UInt64(t[j]) + UInt64(m) * UInt64(modulus[j]) + carry
                    t[j - 1] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                sum = UInt64(t[k]) + carry
                t[k - 1] = UInt32(truncatingIfNeeded: sum)
                t[k] = t[k + 1] + UInt32(truncatingIfNeeded: sum >> 32)
            }
            var out = Array(t[0..<k])
            if t[k] != 0 || !Montgomery.less(out, modulus) { out = Montgomery.subtract(out, modulus) }
            return out
        }

        /// `value mod n` in k limbs, bit by bit from the top: for a value of any size.
        func reduced(_ value: RFBNumber) -> [UInt32] {
            var out = [UInt32](repeating: 0, count: k)
            for index in stride(from: value.bitCount - 1, through: 0, by: -1) {
                var carry: UInt32 = value.bit(index) ? 1 : 0
                var top: UInt32 = 0
                for limb in 0..<k {
                    let next = out[limb] >> 31
                    out[limb] = (out[limb] << 1) | carry
                    carry = next
                }
                top = carry
                if top == 1 || !Montgomery.less(out, modulus) { out = Montgomery.subtract(out, modulus) }
            }
            return out
        }

        func power(_ base: RFBNumber, _ exponent: RFBNumber) -> RFBNumber {
            var one = [UInt32](repeating: 0, count: k)
            one[0] = 1
            let b = multiply(reduced(base), rSquared)
            var x = multiply(one, rSquared)                         // R mod n: one, in Montgomery's form
            for index in stride(from: exponent.bitCount - 1, through: 0, by: -1) {
                x = multiply(x, x)
                if exponent.bit(index) { x = multiply(x, b) }
            }
            return RFBNumber(limbs: multiply(x, one))
        }
    }
}
