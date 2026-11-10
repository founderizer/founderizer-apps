import AppKit
import Testing
@testable import FleetMark

/// The logos are bytes in the source, so a bad edit would show as a provider with no logo on the owner's screens.
struct ProviderLogoTests {
    @Test func eachProviderHasItsLogo() {
        #expect(ProviderLogo.image("claude") != nil)
        #expect(ProviderLogo.image("codex") != nil)
        #expect(ProviderLogo.image("grok") != nil)
        #expect(ProviderLogo.image("another") == nil)
    }

    @Test func eachLogoIsAPictureOf128Pixels() throws {
        for bytes in [ProviderLogo.claudeBytes, ProviderLogo.chatGPTBytes, ProviderLogo.grokBytes] {
            let data = try #require(Data(base64Encoded: bytes))
            let picture = try #require(NSBitmapImageRep(data: data))
            #expect(picture.pixelsWide == 128 && picture.pixelsHigh == 128)
        }
    }
}
