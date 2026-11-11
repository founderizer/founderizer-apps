import Foundation

/// BLAKE2b (RFC 7693), unkeyed, with an output of 1 to 64 bytes: what Argon2 hashes with. Nothing else uses it.
struct Blake2b {
    private static let iv: [UInt64] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                                       0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]]

    private var h: [UInt64]
    private var counter: UInt64 = 0          // bytes compressed; an input of 2^64 bytes is not a case here
    private var block = [UInt8]()            // at most 128 bytes that wait, because the last block is compressed last
    private let length: Int

    init(length: Int) {
        precondition((1...64).contains(length))
        self.length = length
        h = Self.iv
        h[0] ^= 0x0101_0000 ^ UInt64(length)
    }

    static func hash(_ data: [UInt8], length: Int = 64) -> [UInt8] {
        var state = Blake2b(length: length)
        state.update(data)
        return state.final()
    }

    mutating func update(_ data: [UInt8]) {
        var index = 0
        while index < data.count {
            if block.count == 128 { counter &+= 128; compress(block, last: false); block.removeAll(keepingCapacity: true) }
            let take = min(128 - block.count, data.count - index)
            block.append(contentsOf: data[index ..< index + take])
            index += take
        }
    }

    mutating func final() -> [UInt8] {
        counter &+= UInt64(block.count)
        compress(block + [UInt8](repeating: 0, count: 128 - block.count), last: true)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for word in h { for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) } }
        return Array(out.prefix(length))
    }

    private mutating func compress(_ bytes: [UInt8], last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0 ..< 16 {
            var word: UInt64 = 0
            for b in 0 ..< 8 { word |= UInt64(bytes[i * 8 + b]) << UInt64(8 * b) }
            m[i] = word
        }
        var v = h + Self.iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }
        for round in 0 ..< 12 {
            let s = Self.sigma[round % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0 ..< 8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}

extension UInt64 {
    @inline(__always) func rotatedRight(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}

/// Argon2id, version 0x13 (RFC 9106), with no secret and no associated data unless a test gives them: the key
/// derivation of a Bitwarden account that uses Argon2id. `memory` is in KiB, as the RFC counts it.
enum Argon2id {
    enum Failure: Error { case parameters }

    /// The most memory that one derivation may take: 1 GiB, Bitwarden's own upper limit for an account.
    static let memoryLimit = 1_048_576

    static func derive(password: [UInt8], salt: [UInt8], iterations: Int, memory: Int, parallelism: Int, length: Int = 32,
                       secret: [UInt8] = [], associated: [UInt8] = []) throws -> [UInt8] {
        guard (1...16_777_215).contains(parallelism), iterations >= 1, iterations <= 1_000, length >= 4,
              memory >= 8 * parallelism, memory <= memoryLimit, salt.count >= 8 else { throw Failure.parameters }
        var input = [UInt8]()
        for value in [parallelism, length, memory, iterations, 0x13, 2] { input += le32(value) }
        input += le32(password.count) + password + le32(salt.count) + salt
        input += le32(secret.count) + secret + le32(associated.count) + associated
        let h0 = Blake2b.hash(input)

        let segment = memory / (4 * parallelism)
        let laneLength = segment * 4
        let blocks = laneLength * parallelism
        var memoryWords = [UInt64](repeating: 0, count: blocks * 128)
        try memoryWords.withUnsafeMutableBufferPointer { words in
            guard let base = words.baseAddress else { throw Failure.parameters }
            for lane in 0 ..< parallelism {
                for column in 0 ..< 2 {
                    let block = long(h0 + le32(column) + le32(lane), length: 1024)
                    let target = base + (lane * laneLength + column) * 128
                    for i in 0 ..< 128 {
                        var word: UInt64 = 0
                        for b in 0 ..< 8 { word |= UInt64(block[i * 8 + b]) << UInt64(8 * b) }
                        target[i] = word
                    }
                }
            }
            let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: 128 * 5)
            defer { scratch.deallocate() }
            let zero = scratch, input = scratch + 128, address = scratch + 256, work = scratch + 384
            for pass in 0 ..< iterations {
                for slice in 0 ..< 4 {
                    for lane in 0 ..< parallelism {
                        let independent = pass == 0 && slice < 2
                        if independent {
                            for i in 0 ..< 128 { zero[i] = 0; input[i] = 0 }
                            input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice)
                            input[3] = UInt64(blocks); input[4] = UInt64(iterations); input[5] = 2
                        }
                        var start = 0
                        if pass == 0 && slice == 0 {
                            start = 2
                            if independent { nextAddresses(address: address, input: input, zero: zero, work: work) }
                        }
                        var current = lane * laneLength + slice * segment + start
                        var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
                        for index in start ..< segment {
                            if current % laneLength == 1 { previous = current - 1 }
                            let random: UInt64
                            if independent {
                                if index % 128 == 0 { nextAddresses(address: address, input: input, zero: zero, work: work) }
                                random = address[index % 128]
                            } else {
                                random = base[previous * 128]
                            }
                            var referenceLane = Int((random >> 32) % UInt64(parallelism))
                            if pass == 0 && slice == 0 { referenceLane = lane }
                            let reference = referenceIndex(pass: pass, slice: slice, index: index, segment: segment,
                                                           laneLength: laneLength, random: random & 0xFFFF_FFFF,
                                                           sameLane: referenceLane == lane)
                            fill(previous: base + previous * 128, reference: base + (referenceLane * laneLength + reference) * 128,
                                 next: base + current * 128, xor: pass != 0, work: work)
                            current += 1; previous += 1
                        }
                    }
                }
            }
        }
        var final = [UInt64](memoryWords[(laneLength - 1) * 128 ..< laneLength * 128])
        for lane in 1 ..< max(parallelism, 1) {
            let last = (lane * laneLength + laneLength - 1) * 128
            for i in 0 ..< 128 { final[i] ^= memoryWords[last + i] }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(1024)
        for word in final { for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) } }
        for i in memoryWords.indices { memoryWords[i] = 0 }
        return long(bytes, length: length)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    /// H' of RFC 9106, 3.3: a hash of any length from BLAKE2b.
    static func long(_ data: [UInt8], length: Int) -> [UInt8] {
        let input = le32(length) + data
        if length <= 64 { return Blake2b.hash(input, length: length) }
        var out = [UInt8]()
        out.reserveCapacity(length)
        var v = Blake2b.hash(input)
        out += v[0 ..< 32]
        var left = length - 32
        while left > 64 {
            v = Blake2b.hash(v)
            out += v[0 ..< 32]
            left -= 32
        }
        out += Blake2b.hash(v, length: left)
        return out
    }

    private static func referenceIndex(pass: Int, slice: Int, index: Int, segment: Int, laneLength: Int, random: UInt64,
                                       sameLane: Bool) -> Int {
        let area: Int
        if pass == 0 {
            if slice == 0 { area = index - 1 }
            else if sameLane { area = slice * segment + index - 1 }
            else { area = slice * segment + (index == 0 ? -1 : 0) }
        } else {
            area = sameLane ? laneLength - segment + index - 1 : laneLength - segment + (index == 0 ? -1 : 0)
        }
        let x = (random &* random) >> 32
        let relative = UInt64(area) - 1 - ((UInt64(area) &* x) >> 32)
        let start = pass != 0 && slice != 3 ? (slice + 1) * segment : 0
        return Int((UInt64(start) + relative) % UInt64(laneLength))
    }

    private static func nextAddresses(address: UnsafeMutablePointer<UInt64>, input: UnsafeMutablePointer<UInt64>,
                                      zero: UnsafeMutablePointer<UInt64>, work: UnsafeMutablePointer<UInt64>) {
        input[6] &+= 1
        fill(previous: zero, reference: input, next: address, xor: false, work: work)
        fill(previous: zero, reference: address, next: address, xor: false, work: work)
    }

    /// The compression G of RFC 9106, 3.5: next = P(previous ^ reference) ^ (previous ^ reference), and with `xor`
    /// also ^ the block that was there (every pass after the first, version 0x13).
    private static func fill(previous: UnsafeMutablePointer<UInt64>, reference: UnsafeMutablePointer<UInt64>,
                             next: UnsafeMutablePointer<UInt64>, xor: Bool, work: UnsafeMutablePointer<UInt64>) {
        let r = work + 128          // the fifth block of the scratch space
        for i in 0 ..< 128 { r[i] = previous[i] ^ reference[i] }
        for i in 0 ..< 128 { work[i] = r[i] }
        if xor { for i in 0 ..< 128 { r[i] ^= next[i] } }
        for row in 0 ..< 8 {
            let b = row * 16
            permute(work, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for column in 0 ..< 8 {
            let b = column * 2
            permute(work, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49, b + 64, b + 65, b + 80, b + 81, b + 96, b + 97,
                    b + 112, b + 113)
        }
        for i in 0 ..< 128 { next[i] = work[i] ^ r[i] }
    }

    @inline(__always) private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
                                                  _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int,
                                                  _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        @inline(__always) func gb(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            v[a] = v[a] &+ v[b] &+ 2 &* (v[a] & 0xFFFF_FFFF) &* (v[b] & 0xFFFF_FFFF); v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d] &+ 2 &* (v[c] & 0xFFFF_FFFF) &* (v[d] & 0xFFFF_FFFF); v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ 2 &* (v[a] & 0xFFFF_FFFF) &* (v[b] & 0xFFFF_FFFF); v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d] &+ 2 &* (v[c] & 0xFFFF_FFFF) &* (v[d] & 0xFFFF_FFFF); v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }
        gb(i0, i4, i8, i12); gb(i1, i5, i9, i13); gb(i2, i6, i10, i14); gb(i3, i7, i11, i15)
        gb(i0, i5, i10, i15); gb(i1, i6, i11, i12); gb(i2, i7, i8, i13); gb(i3, i4, i9, i14)
    }
}
