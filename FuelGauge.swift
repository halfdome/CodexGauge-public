import Cocoa

func fixedStatusImage(icon: NSImage, text: String, textWidth: CGFloat, font: NSFont) -> NSImage {
    let width: CGFloat = textWidth > 0 ? 33 + textWidth : 32
    let image = NSImage(size: NSSize(width: width, height: 20), flipped: false) { _ in
        icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 20))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: 33, y: floor((20 - size.height) / 2)), withAttributes: attributes)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = text.isEmpty ? "ChatGPT usage" : "ChatGPT usage: \(text)"
    return image
}

func fuelGaugeIcon(used: Double?, stale: Bool, logo: NSImage?) -> NSImage {
    let image = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { _ in
        logo?.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20), from: .zero, operation: .sourceOver, fraction: 1)
        let center = NSPoint(x: 23.5, y: 3.5)
        let radius: CGFloat = 7.5
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 14.5, y: 1.5, width: 17.5, height: 12), xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setStroke(); NSColor.black.setFill()
        let outline = NSBezierPath()
        outline.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
        outline.close()
        if let used {
            // Usage sweeps from empty on the left to full on the right.
            let angle = CGFloat(180 - max(0, min(100, used)) * 1.8)
            let fill = NSBezierPath(); fill.move(to: center)
            fill.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: angle, clockwise: true)
            fill.close(); fill.fill()
        }
        outline.lineWidth = 1.1; outline.lineJoinStyle = .round; outline.stroke()
        NSColor.black.setFill()
        if stale || used == nil { NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 2.5, height: 2.5)).fill() }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "ChatGPT used allowance gauge"
    return image
}
