import CryptoKit

/// scrypt (RFC 7914), which derives a user's key from their secret: slow and
/// heavy on memory, on purpose, so that guessing secrets is too.
enum Scrypt {
    /// The key of a password and a salt, `length` bytes long, at the cost
    /// `n` (a power of 2), the block size `r` and the parallelism `p`.
    static func key(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8] {
        precondition(n > 1 && n & (n - 1) == 0 && n <= 1 << 32, "scrypt: n must be a power of 2")
        let blockBytes = 128 * r, words = 32 * r
        var blocks = pbkdf2(password: password, salt: salt, length: p * blockBytes)
        defer { wipe(&blocks) }

        let v = UnsafeMutablePointer<UInt32>.allocate(capacity: n * words)
        let xy = UnsafeMutablePointer<UInt32>.allocate(capacity: 2 * words + 16)
        v.initialize(repeating: 0, count: n * words)
        xy.initialize(repeating: 0, count: 2 * words + 16)
        defer {
            for (pointer, count) in [(v, n * words), (xy, 2 * words + 16)] {
                pointer.update(repeating: 0, count: count)
                pointer.deallocate()
            }
        }
        blocks.withUnsafeMutableBytes { blocks in
            for i in 0..<p {
                let block = UnsafeMutableRawBufferPointer(rebasing: blocks[i * blockBytes ..< (i + 1) * blockBytes])
                mix(block, r: r, n: n, v: v, xy: xy)
            }
        }
        return pbkdf2(password: password, salt: blocks, length: length)
    }

    /// PBKDF2 with HMAC-SHA-256 and one iteration, as scrypt uses it.
    static func pbkdf2(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var derived: [UInt8] = []
        derived.reserveCapacity(length + SHA256.byteCount)
        var index: UInt32 = 1
        while derived.count < length {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: salt)
            mac.update(data: index.bigEndianBytes)
            derived += mac.finalize()
            index += 1
        }
        return Array(derived.prefix(length))
    }

    /// ROMix: mixes a block of 128·r bytes through v, n blocks of memory.
    /// xy holds two blocks as words, and the 16 words of Salsa20's state.
    private static func mix(_ block: UnsafeMutableRawBufferPointer, r: Int, n: Int,
                            v: UnsafeMutablePointer<UInt32>, xy: UnsafeMutablePointer<UInt32>) {
        let words = 32 * r
        let x = xy, y = xy + words, state = xy + 2 * words
        for i in 0..<words {
            x[i] = UInt32(littleEndian: block.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
        }
        for i in stride(from: 0, to: n, by: 2) {
            (v + i * words).update(from: x, count: words)
            blockMix(state, x, y, r: r)
            (v + (i + 1) * words).update(from: y, count: words)
            blockMix(state, y, x, r: r)
        }
        // The low word of the last 64 bytes picks the block: n is at most 2³².
        let last = (2 * r - 1) * 16, mask = UInt32(truncatingIfNeeded: n - 1)
        for _ in stride(from: 0, to: n, by: 2) {
            xor(x, v + Int(x[last] & mask) * words, count: words)
            blockMix(state, x, y, r: r)
            xor(y, v + Int(y[last] & mask) * words, count: words)
            blockMix(state, y, x, r: r)
        }
        for i in 0..<words {
            block.storeBytes(of: x[i].littleEndian, toByteOffset: 4 * i, as: UInt32.self)
        }
    }

    @inline(__always)
    private static func xor(_ x: UnsafeMutablePointer<UInt32>, _ y: UnsafePointer<UInt32>, count: Int) {
        for i in 0..<count { x[i] ^= y[i] }
    }

    /// BlockMix: Salsa20/8 over the 2·r 64-byte parts of a block, the even
    /// results to the first half of the output, the odd to the second.
    @inline(__always)
    private static func blockMix(_ state: UnsafeMutablePointer<UInt32>, _ input: UnsafePointer<UInt32>,
                                 _ output: UnsafeMutablePointer<UInt32>, r: Int) {
        state.update(from: input + (2 * r - 1) * 16, count: 16)
        for i in stride(from: 0, to: 2 * r, by: 2) {
            salsaXOR(state, input + i * 16, output + i * 8)
            salsaXOR(state, input + i * 16 + 16, output + i * 8 + r * 16)
        }
    }

    /// Salsa20/8 of the state XOR input, into both the state and output.
    @inline(__always)
    private static func salsaXOR(_ state: UnsafeMutablePointer<UInt32>, _ input: UnsafePointer<UInt32>,
                                 _ output: UnsafeMutablePointer<UInt32>) {
        let w0 = state[0] ^ input[0], w1 = state[1] ^ input[1], w2 = state[2] ^ input[2], w3 = state[3] ^ input[3]
        let w4 = state[4] ^ input[4], w5 = state[5] ^ input[5], w6 = state[6] ^ input[6], w7 = state[7] ^ input[7]
        let w8 = state[8] ^ input[8], w9 = state[9] ^ input[9], w10 = state[10] ^ input[10], w11 = state[11] ^ input[11]
        let w12 = state[12] ^ input[12], w13 = state[13] ^ input[13], w14 = state[14] ^ input[14], w15 = state[15] ^ input[15]
        var x0 = w0, x1 = w1, x2 = w2, x3 = w3, x4 = w4, x5 = w5, x6 = w6, x7 = w7
        var x8 = w8, x9 = w9, x10 = w10, x11 = w11, x12 = w12, x13 = w13, x14 = w14, x15 = w15

        for _ in 0..<4 { // 8 rounds, a column round and a row round at a time
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9); x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9); x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9); x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9); x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)

            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9); x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9); x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9); x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9); x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }

        state[0] = x0 &+ w0; state[1] = x1 &+ w1; state[2] = x2 &+ w2; state[3] = x3 &+ w3
        state[4] = x4 &+ w4; state[5] = x5 &+ w5; state[6] = x6 &+ w6; state[7] = x7 &+ w7
        state[8] = x8 &+ w8; state[9] = x9 &+ w9; state[10] = x10 &+ w10; state[11] = x11 &+ w11
        state[12] = x12 &+ w12; state[13] = x13 &+ w13; state[14] = x14 &+ w14; state[15] = x15 &+ w15
        output.update(from: state, count: 16)
    }

    @inline(__always)
    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value &<< count) | (value &>> (32 &- count))
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = 0 }
    }
}

extension UInt32 {
    /// The value's 4 bytes, most significant first.
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { Array($0) } }
}
