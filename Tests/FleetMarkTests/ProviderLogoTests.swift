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

    @Test func eachLogoIsAPictureOf128Pixels() throws {
        for bytes in [ProviderLogo.claudeBytes, ProviderLogo.chatGPTBytes, ProviderLogo.grokBytes, ProviderLogo.geminiBytes,
                      ProviderLogo.openCodeBytes, ProviderLogo.openRouterBytes, ProviderLogo.ollamaBytes] {
            let data = try #require(Data(base64Encoded: bytes))
            let picture = try #require(NSBitmapImageRep(data: data))
            #expect(picture.pixelsWide == 128 && picture.pixelsHigh == 128)
        }
    }
}
