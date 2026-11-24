import Foundation
import Testing
@testable import Founderizer

struct PicturePreviewsTests {
    @MainActor @Test func aChipCanReuseItsPreviewWithoutGivingItToAnotherFileOrSize() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        let previews = PicturePreviews()
        let chip = PicturePreviews.Key(file: "example", pixels: 64)
        let first = await previews.image(chip) { png }
        let again = await previews.image(chip) { nil }
        let otherFile = await previews.image(.init(file: "other", pixels: 64)) { nil }
        let otherSize = await previews.image(.init(file: "example", pixels: 720)) { nil }
        #expect(first != nil && again === first)
        #expect(otherFile == nil && otherSize == nil)
    }
}
