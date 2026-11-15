import CoreGraphics

extension ChatStyle {
    public var title: String {
        switch self {
        case .bubbles: String(localized: "Bubbles")
        case .plain: String(localized: "Plain")
        }
    }

    public var subtitle: String {
        switch self {
        case .bubbles: String(localized: "Yours on the right")
        case .plain: String(localized: "Everyone under their name")
        }
    }
}

/// A small drawing of a chat in a style, for choosing it in Settings: pictures as circles, lines
/// of text as bars, bubbles round them. The same drawing on both platforms, in their colours.
public enum ChatStyleSketch {
    /// The colours to draw in, resolved for the current appearance.
    public struct Palette {
        /// The chat's ground.
        public var background: CGColor
        /// Others' bubbles, and a plain row's pictures.
        public var incoming: CGColor
        /// One's own bubbles and picture: the accent colour.
        public var own: CGColor
        /// A name or a line of text.
        public var ink: CGColor
        /// A line of text on one's own bubble.
        public var inkOnOwn: CGColor

        public init(background: CGColor, incoming: CGColor, own: CGColor, ink: CGColor, inkOnOwn: CGColor) {
            self.background = background
            self.incoming = incoming
            self.own = own
            self.ink = ink
            self.inkOnOwn = inkOnOwn
        }
    }

    /// Draws `style` filling `rect`, in a context whose origin is at the top left (a flipped view's).
    public static func draw(_ style: ChatStyle, in context: CGContext, rect: CGRect, palette: Palette) {
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.clip()
        context.setFillColor(palette.background)
        context.fill(rect)
        // drawn on a 120 x 90 grid, scaled to the rect.
        let scale = min(rect.width / 120, rect.height / 90)
        context.translateBy(x: rect.midX - 60 * scale, y: rect.midY - 45 * scale)
        context.scaleBy(x: scale, y: scale)
        switch style {
        case .bubbles: drawBubbles(context, palette)
        case .plain: drawPlain(context, palette)
        }
    }

    private static func drawBubbles(_ context: CGContext, _ palette: Palette) {
        func bubble(x: CGFloat, y: CGFloat, width: CGFloat, lines: [CGFloat], own: Bool) {
            let height = CGFloat(lines.count) * 7 + 7
            fill(context, CGRect(x: x, y: y, width: width, height: height), radius: 7, own ? palette.own : palette.incoming)
            for (index, length) in lines.enumerated() {
                let line = CGRect(x: own ? x + width - 6 - length : x + 6, y: y + 5 + CGFloat(index) * 7, width: length, height: 3)
                fill(context, line, radius: 1.5, own ? palette.inkOnOwn : palette.ink.copy(alpha: 0.45) ?? palette.ink)
            }
        }
        circle(context, x: 8, y: 31, side: 9, palette.incoming)
        bubble(x: 20, y: 8, width: 54, lines: [40, 26], own: false)
        bubble(x: 20, y: 29, width: 40, lines: [26], own: false)
        bubble(x: 52, y: 46, width: 60, lines: [46, 30], own: true)
        circle(context, x: 8, y: 75, side: 9, palette.incoming)
        bubble(x: 20, y: 70, width: 46, lines: [32], own: false)
    }

    private static func drawPlain(_ context: CGContext, _ palette: Palette) {
        let text = palette.ink.copy(alpha: 0.45) ?? palette.ink
        let time = palette.ink.copy(alpha: 0.25) ?? palette.ink
        func group(y: CGFloat, nameWidth: CGFloat, lines: [CGFloat], own: Bool) {
            circle(context, x: 8, y: y, side: 14, own ? palette.own : palette.incoming)
            fill(context, CGRect(x: 28, y: y + 1, width: nameWidth, height: 4), radius: 2, own ? palette.own : palette.ink)
            fill(context, CGRect(x: 32 + nameWidth, y: y + 1.5, width: 12, height: 3), radius: 1.5, time)
            for (index, length) in lines.enumerated() {
                fill(context, CGRect(x: 28, y: y + 9 + CGFloat(index) * 7, width: length, height: 3), radius: 1.5, text)
            }
        }
        group(y: 8, nameWidth: 22, lines: [78, 56, 66], own: false)
        group(y: 40, nameWidth: 16, lines: [70], own: true)
        group(y: 62, nameWidth: 26, lines: [60, 82], own: false)
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func circle(_ context: CGContext, x: CGFloat, y: CGFloat, side: CGFloat, _ color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: x, y: y, width: side, height: side))
    }
}
