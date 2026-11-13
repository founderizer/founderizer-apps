import AppKit
import FleetCore
import SwiftUI

/// A mark in a rounded tile, as the lead of a list row: an SF Symbol, or the GitHub mark.
struct IconTile<Mark: View>: View {
    private let size: CGFloat
    private let mark: Mark

    init(size: CGFloat = 34, @ViewBuilder mark: () -> Mark) { self.size = size; self.mark = mark() }

    var body: some View {
        mark.font(IconMetrics.symbol(size * 0.44, weight: .light)).foregroundStyle(FleetStyle.text)
            .frame(width: size, height: size)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: size * 0.26))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

extension IconTile where Mark == Image {
    init(symbol: String, size: CGFloat = 34) { self.init(size: size) { Image(systemName: symbol) } }
}

/// The agents that have a secret, a repository or a tool, in the few words of a list row: up to three names, else
/// their count. Two secrets of one variable name differ by these names.
func agentWords(_ names: [String]) -> String {
    names.isEmpty ? String(l10n: "No agent") : names.count <= 3 ? names.map(\.agentLabel).joined(separator: ", ") : String(l10n: "\(names.count) agents")
}

/// The GitHub mark (the Octicons `mark-github` path, MIT license) as a template image: it takes the color of the text.
/// The app bundles no image file; AppKit draws the SVG.
///
/// The path is `icons/mark-github-16.svg` of Octicons (https://github.com/primer/octicons, v19.20.0 has it), under the
/// MIT License, whose notice follows. The GitHub mark is GitHub's: the app shows it only to name GitHub.
///
///     MIT License
///
///     Copyright (c) 2025 GitHub Inc.
///
///     Permission is hereby granted, free of charge, to any person obtaining a copy
///     of this software and associated documentation files (the "Software"), to deal
///     in the Software without restriction, including without limitation the rights
///     to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
///     copies of the Software, and to permit persons to whom the Software is
///     furnished to do so, subject to the following conditions:
///
///     The above copyright notice and this permission notice shall be included in all
///     copies or substantial portions of the Software.
///
///     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
///     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
///     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
///     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
///     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
///     OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
///     SOFTWARE.
struct GitHubMark: View {
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.image).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size).accessibilityHidden(true)
    }

    @MainActor private static let image: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>"#
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
