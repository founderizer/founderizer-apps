import FleetMark
import SwiftUI
import Testing
import UIKit
@testable import FleetMobile

/// The badge of the answer that the agent recommends (owner feature `need_recommended`): its word stays readable on its
/// own fill for every agent's colour on each of the phone's cards. The press on the agent's words is in
/// `SampleFleetTests`, whose sample fleet is one for the whole app.
@Suite("A recommended answer")
@MainActor
struct MobileRecommendedTests {

    /// The sRGB parts of a colour, its opacity last.
    private func parts(_ color: UIColor) -> (Double, Double, Double, Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    /// WCAG's relative luminance of sRGB parts.
    private func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ part: Double) -> Double { part <= 0.04045 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// One look of each of the hues that a glyph can have.
    private var oneLookOfEachHue: [GlyphLook] {
        var looks: [Int: GlyphLook] = [:]
        for number in 0..<500 where looks.count < GlyphLook.toneCount {
            let look = GlyphLook(name: "agent-\(number)")
            if looks[look.tone] == nil { looks[look.tone] = look }
        }
        return Array(looks.values)
    }

    @Test("the badge's word reads 4.5:1 or more on its fill, for every hue, on each of the phone's cards")
    func theWordReadsOnItsFill() throws {
        let looks = oneLookOfEachHue
        #expect(looks.count == GlyphLook.toneCount)
        // the card under the badge, as the catalogue gives it: dark and light, each also under Increase Contrast
        let surface = try #require(UIColor(named: "BrandSurface"))
        for dark in [true, false] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection { traits in
                    traits.userInterfaceStyle = dark ? .dark : .light
                    traits.accessibilityContrast = contrast
                }
                let ground = parts(surface.resolvedColor(with: traits))
                for look in looks {
                    let colours = RecommendedBadge.colours(of: look, dark: dark)
                    let fill = parts(UIColor(colours.fill)), word = parts(UIColor(colours.word))
                    // the fill over the card, as the badge draws it
                    let under = (ground.0 * (1 - fill.3) + fill.0 * fill.3, ground.1 * (1 - fill.3) + fill.1 * fill.3,
                                 ground.2 * (1 - fill.3) + fill.2 * fill.3)
                    let one = luminance(under.0, under.1, under.2), two = luminance(word.0, word.1, word.2)
                    let ratio = (max(one, two) + 0.05) / (min(one, two) + 0.05)
                    #expect(ratio >= 4.5, "hue \(look.tone), \(dark ? "dark" : "light"), \(contrast == .high ? "high" : "normal") contrast: \(ratio)")
                }
            }
        }
    }
}
