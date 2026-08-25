import AppKit

enum MenuBarQuotaRingRenderer {
    static let imageSize = NSSize(width: 14, height: 14)

    static func image(remainingPercent: Int) -> NSImage {
        let progress = MenuBarQuotaIconModel.progress(for: remainingPercent)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current else { return image }
        context.shouldAntialias = true

        let center = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        let radius: CGFloat = 4.9
        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: -270,
            clockwise: true
        )
        track.lineWidth = 1.35
        track.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.24).setStroke()
        track.stroke()

        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * progress,
                clockwise: true
            )
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            arc.stroke()
        } else {
            let dotRect = NSRect(
                x: center.x - 1.15,
                y: center.y - 1.15,
                width: 2.3,
                height: 2.3
            )
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        image.isTemplate = true
        return image
    }
}
