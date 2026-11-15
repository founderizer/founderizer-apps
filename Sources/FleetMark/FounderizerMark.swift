import SwiftUI

/// The product's own mark: a violet plate and two white chevrons, drawn from the same geometry as
/// `founderizer-mark.svg` and `make-icon.py`, so the app, the icon and the website cannot drift apart.
///
/// It is a drawing and not a picture, so it is sharp at any size and can be faded into a background, which is what
/// the first-run wizard does with it.
public struct FounderizerMark: View {
    /// The violet of the brand (`#635BFF`).
    public static let violet = Color(red: 0x63 / 255, green: 0x5B / 255, blue: 0xFF / 255)
    /// The side of the mark in the original drawing: every point below is in this square.
    private static let side: CGFloat = 512

    public var size: CGFloat
    /// The plate's colour. A background watermark takes the violet at a low opacity; the mark itself takes it whole.
    public var plate: Color
    /// The chevrons' colour.
    public var ink: Color

    public init(size: CGFloat, plate: Color = FounderizerMark.violet, ink: Color = .white) {
        self.size = size; self.plate = plate; self.ink = ink
    }

    /// The two chevrons in the square of the original drawing (`side`), each with the width of its stroke there.
    public static let chevrons: [(points: [CGPoint], width: CGFloat)] = [
        ([CGPoint(x: 172, y: 217), CGPoint(x: 256, y: 133), CGPoint(x: 340, y: 217)], 50),
        ([CGPoint(x: 148, y: 373), CGPoint(x: 256, y: 265), CGPoint(x: 364, y: 373)], 62),
    ]

    public var body: some View {
        let scale = size / FounderizerMark.side
        ZStack {
            RoundedRectangle(cornerRadius: 116 * scale, style: .continuous).fill(plate)
            ForEach(0..<Self.chevrons.count, id: \.self) { index in
                chevron(Self.chevrons[index].points, width: Self.chevrons[index].width * scale, scale: scale)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func chevron(_ points: [CGPoint], width: CGFloat, scale: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: points[0].x * scale, y: points[0].y * scale))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale)) }
        }
        .stroke(ink, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
