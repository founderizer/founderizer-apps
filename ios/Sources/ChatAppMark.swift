import FleetCore
import SwiftUI

/// The mark of the chat app a message of his came from, on the corner of its bubble (the owner's yes of 28 October 2026
/// to D-7): the WhatsApp or the Discord mark in its brand's colour, in a small round tile of the page's own colour. His
/// own apps — this phone and the Mac — have none: they are the usual case, and the words "iPhone" and "Mac" under each
/// run told him nothing he acts on.
struct ChatAppMark: View {
    /// `whatsapp` or `discord`.
    let app: String
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 26

    var body: some View {
        BrandMarkShape(data: app == "whatsapp" ? Self.whatsApp : Self.discord)
            .fill(app == "whatsapp" ? Self.whatsAppColor : Self.discordColor)
            .frame(width: side * 0.72, height: side * 0.72)
            .frame(width: side, height: side)
            .background(Brand.canvas, in: Circle())
            .accessibilityElement()
            .accessibilityLabel(app == "whatsapp" ? "Sent from WhatsApp" : "Sent from Discord")
    }

    /// The chat app of a message's client label (`messageSource`): the hub's channels write their own
    /// (`fleet-channels/1/<account>`). This phone, the Mac and any other client have none.
    static func app(of client: String?) -> String? {
        switch messageSource(client) {
        case "Discord": "discord"
        case "WhatsApp": "whatsapp"
        default: nil
        }
    }

    // The brands' own colours, as the Mac's Channels cards draw them: WhatsApp #25D366, Discord #5865F2.
    private static let whatsAppColor = Color(red: 0x25 / 255, green: 0xD3 / 255, blue: 0x66 / 255)
    private static let discordColor = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)

    // Simple Icons 16.34.0 (CC0), icons/whatsapp.svg and icons/discord.svg: the path data the Mac's `BrandMark` draws.
    private static let whatsApp = "M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z"
    private static let discord = "M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"
}

/// A mark of SVG path data in a 24-point box, as Simple Icons draws them, scaled to the space it is given. The Mac
/// hands the same data to AppKit, which reads SVG; this platform's images do not, so the path is read here: every
/// command of the path syntax, the arcs as cubic curves, and the tokens split by FleetCore's own `ChatApps.spacedPath`.
struct BrandMarkShape: Shape {
    let data: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Self.read(data).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }

    /// The path of the data, in its own 24-point box.
    static func read(_ data: String) -> Path {
        var path = Path()
        let tokens = ChatApps.spacedPath(data).split(separator: " ").map(String.init)
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        /// The last control point of a curve, which a smooth curve mirrors, and the kind of that curve.
        var control: CGPoint?
        var quadratic = false

        func isCommand(_ token: String) -> Bool { token.count == 1 && token.first?.isLetter == true }
        func number() -> CGFloat {
            defer { index += 1 }
            return index < tokens.count ? CGFloat(Double(tokens[index]) ?? 0) : 0
        }
        func point(_ relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < tokens.count {
            if isCommand(tokens[index]) {
                command = tokens[index].first ?? "M"
                index += 1
            }
            let relative = command.isLowercase
            switch command {
            case "Z", "z":
                path.closeSubpath()
                current = start
                control = nil
                continue
            case "M", "m":
                current = point(relative)
                start = current
                path.move(to: current)
                // Pairs after a move are lines.
                command = relative ? "l" : "L"
                control = nil
            case "L", "l":
                current = point(relative)
                path.addLine(to: current)
                control = nil
            case "H", "h":
                let x = number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                control = nil
            case "V", "v":
                let y = number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                control = nil
            case "C", "c":
                let first = point(relative), second = point(relative), end = point(relative)
                path.addCurve(to: end, control1: first, control2: second)
                control = second; quadratic = false
                current = end
            case "S", "s":
                let first = control.map { quadratic ? current : CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) }
                    ?? current
                let second = point(relative), end = point(relative)
                path.addCurve(to: end, control1: first, control2: second)
                control = second; quadratic = false
                current = end
            case "Q", "q":
                let middle = point(relative), end = point(relative)
                path.addQuadCurve(to: end, control: middle)
                control = middle; quadratic = true
                current = end
            case "T", "t":
                let middle = control.map { quadratic ? CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) : current }
                    ?? current
                let end = point(relative)
                path.addQuadCurve(to: end, control: middle)
                control = middle; quadratic = true
                current = end
            case "A", "a":
                let rx = number(), ry = number(), rotation = number()
                let large = number() != 0, sweep = number() != 0
                let end = point(relative)
                arc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                control = nil
            default:
                // A command this reader does not know ends the mark rather than drawing a wrong one.
                return path
            }
        }
        return path
    }

    /// An elliptical arc of the path syntax as cubic curves of at most a quarter turn each (SVG 1.1, appendix F.6.5).
    private static func arc(_ path: inout Path, from begin: CGPoint, to end: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        guard begin != end else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let halfX = (begin.x - end.x) / 2, halfY = (begin.y - end.y) / 2
        let x1 = cosPhi * halfX + sinPhi * halfY
        let y1 = -sinPhi * halfX + cosPhi * halfY
        // Radii too small for the two ends grow until they reach.
        let reach = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if reach > 1 { rx *= reach.squareRoot(); ry *= reach.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator > 0 ? max(0, numerator / denominator).squareRoot() : 0
        if large == sweep { factor = -factor }
        let centreX1 = factor * rx * y1 / ry
        let centreY1 = -factor * ry * x1 / rx
        let centre = CGPoint(x: cosPhi * centreX1 - sinPhi * centreY1 + (begin.x + end.x) / 2,
                             y: sinPhi * centreX1 + cosPhi * centreY1 + (begin.y + end.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let turn = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return turn
        }
        let ux = (x1 - centreX1) / rx, uy = (y1 - centreY1) / ry
        let vx = (-x1 - centreX1) / rx, vy = (-y1 - centreY1) / ry
        let first = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(pieces)
        let handle = 4 / 3 * tan(step / 4)
        func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + centre.x, y: sinPhi * rx * x + cosPhi * ry * y + centre.y)
        }
        var theta = first
        for _ in 0..<pieces {
            let next = theta + step
            path.addCurve(to: onEllipse(cos(next), sin(next)),
                          control1: onEllipse(cos(theta) - handle * sin(theta), sin(theta) + handle * cos(theta)),
                          control2: onEllipse(cos(next) + handle * sin(next), sin(next) - handle * cos(next)))
            theta = next
        }
    }
}
