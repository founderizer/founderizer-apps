import AppKit
import Testing
@testable import FleetMark

/// The logos are bytes in the source, so a bad edit would show as a provider with no logo on the owner's screens.
struct ProviderLogoTests {
    @Test func eachProviderHasItsLogo() {
        #expect(ProviderLogo.image("claude") != nil)
        #expect(ProviderLogo.image("codex") != nil)
        #expect(ProviderLogo.image("grok") != nil)
        // The AI providers build: the providers of an agent on a key (`ModelProvider.logo`).
        for name in ["gemini", "opencode", "openrouter", "ollama"] { #expect(ProviderLogo.image(name) != nil, "\(name)") }
        #expect(ProviderLogo.image("another") == nil)
    }

    /// **An AI session's mark is its logo's glyph alone** (owner feature `message_hands`: the glyph in white on the tile of
    /// a chat app's mark). The bugs that this catches: no glyph for a program that the hub names, so the bubble's corner
    /// shows an empty tile; a glyph for a program that has no mark; and a glyph read the wrong way round (the tile and
    /// not the star, the knot, the ball or the frame), which has other bounds and another share of them opaque.
    @Test func eachProgramOfAnAISessionHasTheGlyphOfItsLogoAlone() throws {
        for name in ["claude", "codex", "grok", "opencode"] { #expect(ProviderLogo.glyph(name) != nil, "\(name)") }
        for name in ["gemini", "ollama", "another"] { #expect(ProviderLogo.glyph(name) == nil, "\(name)") }
        let glyphs: [(name: String, bytes: String, tones: ProviderLogo.Tones, wide: Int, high: Int, share: Double)] = [
            ("claude", ProviderLogo.claudeBytes, ProviderLogo.claudeTones, 76, 76, 0.39),
            ("codex", ProviderLogo.chatGPTBytes, ProviderLogo.chatGPTTones, 82, 82, 0.395),
            ("grok", ProviderLogo.grokBytes, ProviderLogo.grokTones, 92, 80, 0.68),
            ("opencode", ProviderLogo.openCodeBytes, ProviderLogo.openCodeTones, 43, 54, 0.73)]
        for glyph in glyphs {
            let mask = try #require(ProviderLogo.glyphMask(glyph.bytes, glyph.tones), "\(glyph.name)")
            let pixels = try #require(mask.dataProvider?.data as Data?)
            let opaque = stride(from: 3, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) / 255 }
            let share = opaque / Double(mask.width * mask.height)
            #expect(abs(mask.width - glyph.wide) <= 3 && abs(mask.height - glyph.high) <= 3,
                    "\(glyph.name): \(mask.width)x\(mask.height)")
            #expect(abs(share - glyph.share) <= 0.04, "\(glyph.name): \(share) of its bounds")
        }
    }

    @Test func eachLogoIsAPictureOf128Pixels() throws {
        for bytes in [ProviderLogo.claudeBytes, ProviderLogo.chatGPTBytes, ProviderLogo.grokBytes, ProviderLogo.geminiBytes,
                      ProviderLogo.openCodeBytes, ProviderLogo.openRouterBytes, ProviderLogo.ollamaBytes] {
            let data = try #require(Data(base64Encoded: bytes))
            let picture = try #require(NSBitmapImageRep(data: data))
            #expect(picture.pixelsWide == 128 && picture.pixelsHigh == 128)
        }
    }
}
