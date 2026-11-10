import AppKit
import Testing
@testable import FleetMark

/// The cloud providers' logos are bytes in the source, as the AI providers' are, so a bad edit would show as a VPS card
/// with no logo on the owner's screen.
struct CloudLogoTests {
    @Test func eachCloudProviderHasItsLogo() {
        for provider in ["hetzner", "digitalocean", "vultr", "akamai"] {
            #expect(CloudLogo.image(provider) != nil, "\(provider)")
        }
        #expect(CloudLogo.image("another") == nil)
        // Hetzner's red square is its whole tile; every other mark stands in the middle of a white one.
        #expect(CloudLogo.fillsTile("hetzner"))
        #expect(!CloudLogo.fillsTile("digitalocean") && !CloudLogo.fillsTile("vultr") && !CloudLogo.fillsTile("akamai"))
    }

    @Test func eachLogoIsAPictureOf128Pixels() throws {
        for bytes in [CloudLogo.hetznerBytes, CloudLogo.digitalOceanBytes, CloudLogo.vultrBytes, CloudLogo.akamaiBytes] {
            let data = try #require(Data(base64Encoded: bytes))
            let picture = try #require(NSBitmapImageRep(data: data))
            #expect(picture.pixelsWide == 128 && picture.pixelsHigh == 128)
        }
    }
}
