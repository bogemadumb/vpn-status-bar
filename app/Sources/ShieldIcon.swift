import AppKit

enum ShieldIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(for state: VPNState) -> NSImage {
        let key = "\(state)"
        if let c = cache[key] { return c }
        let img = draw(state: state)
        cache[key] = img
        return img
    }

    private static func dotColor(_ s: VPNState) -> NSColor? {
        switch s {
        case .ok: return NSColor(srgbRed: 0x3D / 255, green: 0xBA / 255, blue: 0x7E / 255, alpha: 1)
        case .slow, .degraded, .connecting: return NSColor(srgbRed: 0xE5 / 255, green: 0xA4 / 255, blue: 0x3B / 255, alpha: 1)
        case .down: return NSColor(srgbRed: 0xF0 / 255, green: 0x55 / 255, blue: 0x3A / 255, alpha: 1)
        case .off: return nil
        }
    }

    static func draw(state: VPNState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let dot = dotColor(state)
        let img = NSImage(size: size, flipped: true) { _ in
            let k: CGFloat = 18.0 / 24.0
            let tf = AffineTransform(scaleByX: k, byY: k)
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 12, y: 2.6))
            shield.line(to: NSPoint(x: 4.6, y: 5.4))
            shield.line(to: NSPoint(x: 4.6, y: 11.5))
            shield.curve(to: NSPoint(x: 12, y: 21.4), controlPoint1: NSPoint(x: 4.6, y: 16.1), controlPoint2: NSPoint(x: 7.7, y: 19.6))
            shield.curve(to: NSPoint(x: 19.4, y: 11.5), controlPoint1: NSPoint(x: 16.3, y: 19.6), controlPoint2: NSPoint(x: 19.4, y: 16.1))
            shield.line(to: NSPoint(x: 19.4, y: 5.4))
            shield.close()
            shield.transform(using: tf)
            shield.lineWidth = 1.8 * k
            shield.lineJoinStyle = .round
            shield.lineCapStyle = .round

            let center = NSPoint(x: 18.6 * k, y: 18.6 * k)
            NSGraphicsContext.saveGraphicsState()
            if dot != nil {
                let clip = NSBezierPath(rect: NSRect(x: -2, y: -2, width: 22, height: 22))
                clip.appendOval(in: NSRect(x: center.x - 4.4 * k, y: center.y - 4.4 * k, width: 8.8 * k, height: 8.8 * k))
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            let fg = dot == nil ? NSColor.labelColor.withAlphaComponent(0.4) : NSColor.labelColor
            fg.setStroke()
            shield.stroke()
            NSGraphicsContext.restoreGraphicsState()

            if let d = dot {
                d.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 3.1 * k, y: center.y - 3.1 * k, width: 6.2 * k, height: 6.2 * k)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
