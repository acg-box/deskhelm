import AppKit

@MainActor
enum DeskHelmStatusIcon {
  static func makeImage() -> NSImage {
    let statusImage = NSImage(
      size: NSSize(width: 18, height: 17),
      flipped: false
    ) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else {
        return false
      }

      context.saveGState()
      context.translateBy(x: 0, y: -1)
      context.setStrokeColor(NSColor.black.cgColor)
      context.setFillColor(NSColor.black.cgColor)
      context.setLineCap(.round)
      context.setLineJoin(.round)

      context.setLineWidth(1.6)
      context.addPath(
        CGPath(
          roundedRect: CGRect(
            x: 1.25,
            y: 4,
            width: 15.5,
            height: 10.25
          ),
          cornerWidth: 2.2,
          cornerHeight: 2.2,
          transform: nil
        )
      )
      context.strokePath()

      context.move(to: CGPoint(x: 9, y: 4))
      context.addLine(to: CGPoint(x: 9, y: 2.5))
      context.move(to: CGPoint(x: 6.25, y: 2))
      context.addLine(to: CGPoint(x: 11.75, y: 2))
      context.strokePath()

      context.setLineWidth(1.35)
      context.move(to: CGPoint(x: 4.5, y: 9.125))
      context.addLine(to: CGPoint(x: 13.5, y: 9.125))
      context.strokePath()
      context.fillEllipse(
        in: CGRect(x: 7.125, y: 7.25, width: 3.75, height: 3.75)
      )

      context.restoreGState()
      return true
    }

    statusImage.alignmentRect = NSRect(
      x: 0,
      y: 2.5,
      width: 18,
      height: 10.5
    )
    statusImage.accessibilityDescription = "DeskHelm"
    statusImage.isTemplate = true
    return statusImage
  }
}
