import Foundation
import Testing
@testable import FleetCore

// The take-over card's own client of an agent's screen (`RemoteScreen/`). The fixed values come from Python's `pow`,
// `hashlib` and `zlib` and from `openssl enc` (DES and AES-128 in ECB mode), outside this code.
struct RemoteScreenTests {
    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// A Mac's sign-in rests on this power: a wrong carry in Montgomery's sum gives a key that the Mac refuses.
    @Test func thePowerIsPythonsPow() {
        let p = RFBNumber(bigEndian: Self.bytes("942c83647806857713e783e7eb04b39b68b4aef73eaabe171d8a4eace693ae2d9a1e40b458151a9959e2d15364c7a5005d32fe61985fb4e72a095ee82bb2997659ba1b0d5c9061582909406c2e416788f5ec52ed0108847512e1bc7656670b141509bb0a9bf13331ca118783593942a447eaa0992cb6916d86dc283cf0480ff9"))
        let b = RFBNumber(bigEndian: Self.bytes("0954ee889fe46f2c7a8c627bf3225fac9cb6e34acb115ee347dd9ed89eddd6846325b600e6129ec04ece4350cc1721e52f212cd552a09ddbef12de1b1471320a88ea37a788d1067628326e704245a4ff91e3e7949b80dcb0b82ec0290103855dbf5559ec8712e8e3574f00a154d85ed8abcc35c719c2add9ca883b041641178854f2260df25453fe2e85"))
        let e = RFBNumber(bigEndian: Self.bytes("6470ff1f134b8db4b18fbdb1c44a66f4cf25e3465cbe4f50bdbcda989672be1a7fed0bb9a92fa271dbc529331dcd327f761e07cb7b7e8913655c1d1578f6d82486ea0214b5c34e7e77ca4499e07cb5793e7fb97bfcc1c0c8b0cdf20a990d3cd8381df22f050c86bd84e0164b43f2f1936e85df0875927b0fe339d309a930d55d"))
        #expect(b.power(e, modulus: p)?.bigEndian(count: 128) == Self.bytes("6a746b4174c657bc827b684419b4cc9b3b0865ca5c0126c3b6e897bca1271b084d317a0c67570eedb9df7ad8a695f66cea9ebcfd4b21274316c2d7a6853813279cd55ee971e7fbe0ede1d0b5e53906f7152f0f112c155680a7e33b6910ef9e3c025cc31809ad7c2970c13b24f14f5328725521d8115556a2839b495f9128c0b6"))
        #expect(b.power(e, modulus: RFBNumber(limbs: [10])) == nil)                    // an even modulus
    }

    /// VNC's key is the password's first 8 bytes with each byte's bits reversed: without the reversal every
    /// server refuses the one-time password.
    @Test func vncsAnswerIsDESUnderTheReversedKey() {
        #expect(RFBVNCSignIn.response(challenge: Self.bytes("101112131415161718191a1b1c1d1e1f"),
                                      password: "s3cretpassword") == Self.bytes("8828782b50f9a21891bb941810884dff"))
    }

    /// A Mac reads 128 encrypted bytes (name, then password, each in 64 bytes ending with a zero) and then the
    /// client's public key: another order, or no MD5 of the shared secret, is a refused sign-in.
    @Test func aMacsSignInIsTheAccountEncryptedThenThePublicKey() {
        let offer = RFBAppleSignIn.Offer(generator: [0, 2], prime: Self.bytes("c37ee1e269fa541c228a31298a9e1df7e771876ead783715ee6f7a8f79ded9f207d3b36c505bdd8f4ed3d99ebbb3a32acf00377c7a674d0a5fd11a3264e752cc93a9b8b601f72b0a43c20f56310a853eec9a72f24ea9877af376bc252e460a9618949a23d9855162fd0b00ea4f859933fdf0a45f57e485b6761978dd1e2ed6cb"),
                                         serverKey: Self.bytes("a8cc915b7d838d54ce79700a38ef408327f9a26021acd46b0f2e798655f90d528398ef292b7f3f2c8567ff6cad2539b534c3376c8d4530fea4aa0e716c373f84b0cd36318f9fda65402037b1730ad0b702c5be0c72e92c142f69e409ef86d228fce004fe5c15dc7f70a79019fae4e52679ea7bc3e1e8b69450a53fc8f8613481"))
        let response = RFBAppleSignIn.response(to: offer, user: "example", password: "correct horse",
                                               privateKey: Self.bytes("a70ff8330c4d719ec7bfbfc1d9fe279f1addb88d09aca93b034e64eff0ad52b3c3cc411c6db644c0fee85a57fc9b3904c17e127b35baaa7b437acfa1b61d3183abbd3f3fbf902456cf980f951ce3923fcd76d4d9b1cac733f4fb474e95e2f04826ba9153bde3221553efdeed7f9f6f4756a0cda0172bac7c603c0eea66"),
                                               filler: Self.bytes("427e13f0c10b4eb388a30fb2330d9c87370b093363ce3a372aa5e681cb8baf2a4ce64b452cf9b28514c183c5d21df48e929fed79f8daf345e050358972873bd530c8aaf6426cdae01aa59dfac63b0392ef2dcefc3ecc4b39f352463498c062da5f0e910723833dc3e46ef783d15ea996a04762ee128dcfc75a39ade18d51414b"))
        #expect(response == Self.bytes("a948e8b6f28e84a4cca8f0ed025c8ba8172533f676bafddb90e4a4f6158c78078884f6691d7f5fc3e143067cdc2c0b3d8478452d0d040ff7595d2c25e106eca98f305a86dd76a1692e498e57f804e8d2a411de364c56a88f678b58577c4ff1e892cdca8fa3667f40c523e6636436ea8e4c4542d276ccf1dba9690664b95d1287580339990bf38e6f29adb2b06add7d4bf9dbb6db90e7cafd9826712120449b3b2d8e34a770d2569924e596ac356f23b2952fb80b2e7705681107cede82b6a020a07e8f812aa1fce4528e3ed385834285543fa3ad00d3ca1d61e9e54fa0f61bb1ccf678d7cae67e04d4bb38d18a58cb0f04db352a0933e605f287d7aa5b17ab81"))
        // a password of 64 bytes or more has no place in its 64 bytes with the zero: nothing is sent
        #expect(RFBAppleSignIn.response(to: offer, user: "example", password: String(repeating: "x", count: 64)) == nil)
        // a server key of p−1 makes the shared secret 1 or p−1, which anybody can read: nothing is sent
        let weak = RFBAppleSignIn.Offer(generator: [0, 2], prime: offer.prime,
                                        serverKey: RFBNumber(bigEndian: offer.prime).lessOne.bigEndian(count: 128)!)
        #expect(RFBAppleSignIn.response(to: weak, user: "example", password: "correct horse") == nil)
    }

    /// ZRLE has one zlib stream for the whole session: a decoder that starts a new stream at each rectangle reads
    /// the second rectangle as garbage. The three rectangles are a packed palette, a plain run and a palette run.
    @Test func zrleReadsOneStreamAcrossRectangles() throws {
        let screen = RFBFramebuffer(width: 12, height: 4)
        try screen.zrle(x: 0, y: 0, width: 5, height: 2, compressed: Self.bytes("789c626260f8ff9f81614100000000ffff"))
        try screen.zrle(x: 5, y: 0, width: 4, height: 3, compressed: Self.bytes("6a60f8cfc0f2ffff7f3600000000ffff"))
        try screen.zrle(x: 0, y: 2, width: 3, height: 2, compressed: Self.bytes("6a9213e1b231d26860666404000000ffff"))
        func rgb(_ x: Int, _ y: Int) -> [UInt8] {
            let at = (y * 12 + x) * 4
            return [screen.pixels[at + 2], screen.pixels[at + 1], screen.pixels[at]]
        }
        let red: [UInt8] = [255, 0, 0], blue: [UInt8] = [0, 0, 255], green: [UInt8] = [0, 255, 0]
        let white: [UInt8] = [255, 255, 255], first: [UInt8] = [10, 20, 30], second: [UInt8] = [40, 50, 60]
        #expect((0..<5).map { rgb($0, 0) } == [blue, red, blue, red, red])
        #expect((0..<5).map { rgb($0, 1) } == [red, blue, red, blue, red])
        #expect((5..<9).map { rgb($0, 0) } == [green, green, green, green])
        #expect((5..<9).map { rgb($0, 1) } == [green, white, white, white])
        #expect((0..<3).map { rgb($0, 2) } == [first, first, first])
        #expect((0..<3).map { rgb($0, 3) } == [first, second, second])
        #expect(throws: RFBDecodeError.outside) {
            try screen.zrle(x: 10, y: 0, width: 4, height: 1, compressed: [])
        }
    }

    // MARK: the session, against a scripted screen

    /// A screen whose bytes come in small pieces, as a network gives them; it ends when its script ends.
    private final class ScriptedScreen: RFBTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pieces: [Data]
        private(set) var sent: [UInt8] = []

        init(_ script: [UInt8]) {
            pieces = stride(from: 0, to: script.count, by: 3).map { Data(script[$0..<min($0 + 3, script.count)]) }
        }

        func receive() async throws -> Data {
            lock.withLock { pieces.isEmpty ? Data() : pieces.removeFirst() }
        }

        func send(_ data: Data) async throws {
            lock.withLock { sent += data }
        }

        func close() {}

        var written: [UInt8] { lock.withLock { sent } }
    }

    private static func serverInit(width: UInt16, height: UInt16) -> [UInt8] {
        [UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)] + [UInt8](repeating: 0, count: 16)
            + [0, 0, 0, 5] + Array("agent".utf8)
    }

    /// A Mac answers "RFB 003.889": the client answers 3.8 and signs in with Apple's type 30 and the account, never
    /// with VNC's type 2, which would carry the first 8 characters of the Mac's password.
    @Test func aMacsScreenIsAnsweredAs38AndSignsInWithItsAccount() async throws {
        let prime = [0xC0] + [UInt8](repeating: 0, count: 62) + [5]          // 512 bits, odd
        var script = Array("RFB 003.889\n".utf8) + [2, 2, 30]
        script += [0, 2, 0, 64] + prime + [UInt8](repeating: 0, count: 63) + [4]
        script += [0, 0, 0, 0] + Self.serverInit(width: 4, height: 2)
        let screen = ScriptedScreen(script)
        let session = RFBSession(transport: screen)
        let facts = try await session.start(credentials: .account(user: "example", password: "a password"))
        #expect(facts == RFBScreen(width: 4, height: 2, name: "agent"))
        let sent = screen.written
        #expect(Array(sent.prefix(12)) == Array("RFB 003.008\n".utf8))
        #expect(sent[12] == 30)
        // 128 encrypted bytes and a public key of the prime's 64, then ClientInit's 1 (shared)
        #expect(sent[13 + 128 + 64] == 1)
        let tail = Array(sent.suffix(from: 13 + 128 + 64 + 1))
        #expect(Array(tail.prefix(20)) == RFBSession.pixelFormat)
        #expect(Array(tail[20..<24]) == [2, 0, 0, 5])                         // five encodings, ZRLE first
        #expect(Array(tail[24..<28]) == [0, 0, 0, 16])
        #expect(Array(tail.suffix(10)) == [3, 0, 0, 0, 0, 0, 0, 4, 0, 2])      // the first, whole-screen update
    }

    /// The one-time password of a Linux agent's screen goes only into VNC's sign-in, and a Mac's account only into
    /// Apple's: a screen that offers neither for the credentials gets no answer at all.
    @Test func credentialsGoOnlyToTheirOwnSignIn() async {
        let screen = ScriptedScreen(Array("RFB 003.889\n".utf8) + [1, 30])
        await #expect(throws: RFBError.noSignIn) {
            _ = try await RFBSession(transport: screen).start(credentials: .password("one-time"))
        }
        #expect(screen.written == Array("RFB 003.008\n".utf8))
    }

    /// An offer that cannot carry the password (here a prime of 1) is unreadable, never a refusal of the screen's:
    /// the card drops a kept Mac password only when the screen itself refuses it.
    @Test func aBadOfferIsNoRefusal() async {
        let one = [UInt8](repeating: 0, count: 63) + [1]
        let script = Array("RFB 003.889\n".utf8) + [1, 30] + [0, 2, 0, 64] + one + one
        let screen = ScriptedScreen(script)
        await #expect(throws: RFBError.unreadable("sign-in offer")) {
            _ = try await RFBSession(transport: screen).start(credentials: .account(user: "example", password: "a password"))
        }
        #expect(screen.written == Array("RFB 003.008\n".utf8) + [30])               // nothing of the password went
    }

    /// A screen that names a size of gigabytes is refused before any memory is taken for it.
    @Test func aScreenTooLargeIsRefused() async {
        let script = Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0] + [0xFF, 0xFF, 0xFF, 0xFF]
        await #expect(throws: RFBError.unreadable("screen size")) {
            _ = try await RFBSession(transport: ScriptedScreen(script)).start(credentials: .none)
        }
    }

    /// A refused password gives the screen's own words, so the card can ask for the Mac's password again.
    @Test func aRefusedSignInGivesTheScreensWords() async {
        let words = Array("Authentication failed".utf8)
        let script = Array("RFB 003.008\n".utf8) + [1, 2] + [UInt8](repeating: 7, count: 16) + [0, 0, 0, 1]
            + [0, 0, 0, UInt8(words.count)] + words
        await #expect(throws: RFBError.signInRefused("Authentication failed")) {
            _ = try await RFBSession(transport: ScriptedScreen(script)).start(credentials: .password("one-time"))
        }
    }

    /// One update with Raw, CopyRect and Hextile gives one whole screen; the server's clipboard is read and
    /// dropped (it never reaches his Mac), and the client asks for the next update after each one.
    @Test func anUpdateDrawsRawCopyAndHextileAndTheClipboardIsDropped() async throws {
        var script = Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0] + Self.serverInit(width: 4, height: 2)
        script += [3, 0, 0, 0, 0, 0, 0, 6] + Array("secret".utf8)               // ServerCutText
        script += [0, 0, 0, 3]                                                   // an update of three rectangles
        script += [0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0] + [1, 2, 3, 0, 4, 5, 6, 0]  // Raw 2x1 at (0,0)
        script += [0, 2, 0, 0, 0, 2, 0, 1, 0, 0, 0, 1] + [0, 0, 0, 0]              // CopyRect of (0,0) to (2,0)
        // Hextile 4x1 at (0,1): background 9,9,9 and one subrectangle of 7,7,7 at (1,0), 2x1
        script += [0, 0, 0, 1, 0, 4, 0, 1, 0, 0, 0, 5] + [2 | 4 | 8, 9, 9, 9, 0, 7, 7, 7, 0, 1, 0x10, 0x10]
        let screen = ScriptedScreen(script)
        let session = RFBSession(transport: screen)
        _ = try await session.start(credentials: .none)
        let before = screen.written.count
        let frames = FrameBox()
        await #expect(throws: RFBError.closed) { try await session.run { frames.add($0) } }
        let got = frames.all
        #expect(got.count == 1)
        #expect(Array(got.first?.pixels ?? Data()) == [1, 2, 3, 0, 4, 5, 6, 0, 1, 2, 3, 0, 4, 5, 6, 0,
                                                       9, 9, 9, 0, 7, 7, 7, 0, 7, 7, 7, 0, 9, 9, 9, 0])
        let after = Array(screen.written.suffix(from: before))
        #expect(after == [3, 1, 0, 0, 0, 0, 0, 4, 0, 2])                         // the next update, incremental
        // his input: a click clamps to the screen, a key goes as its keysym
        await session.pointer(x: 99, y: -5, buttons: 1)
        await session.key(0xF1, down: true)
        #expect(Array(screen.written.suffix(14)) == [5, 1, 0, 3, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0xF1])
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [RFBFrame] = []
        func add(_ frame: RFBFrame) { lock.withLock { frames.append(frame) } }
        var all: [RFBFrame] { lock.withLock { frames } }
    }

    /// A character key goes as its own keysym (ñ as ñ), a key that writes nothing by the Mac's key code, and Esc
    /// has none: it closes the card.
    @Test func keysGoAsKeysymsAndEscStaysInTheApp() {
        #expect(RFBKeys.keysym(for: "ñ") == 0xF1)
        #expect(RFBKeys.keysym(for: "€") == 0x0100_20AC)
        #expect(RFBKeys.keysym(for: "\r") == nil)
        #expect(RFBKeys.special(macKeyCode: 0x24) == 0xFF0D)
        #expect(RFBKeys.special(macKeyCode: 0x35) == nil)                         // Esc
    }
}
