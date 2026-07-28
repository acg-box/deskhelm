import AppKit
import SwiftUI

struct PermissionAppDragSource: NSViewRepresentable {
  private let bundleURL: URL
  private let icon: NSImage
  private let label: String

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    icon: NSImage? = nil,
    label: String = "DeskHelm.app"
  ) {
    self.bundleURL = bundleURL
    self.icon = icon ?? NSWorkspace.shared.icon(forFile: bundleURL.path)
    self.label = label
  }

  func makeNSView(context: Context) -> PermissionAppDragSourceView {
    PermissionAppDragSourceView(
      bundleURL: bundleURL,
      icon: icon,
      label: label
    )
  }

  func updateNSView(
    _ nsView: PermissionAppDragSourceView,
    context: Context
  ) {
    nsView.configure(
      bundleURL: bundleURL,
      icon: icon,
      label: label
    )
  }
}

final class PermissionAppDragSourceView: NSView, NSDraggingSource {
  private var bundleURL: URL
  private var icon: NSImage
  private var label: String
  private var dragStarted = false

  init(bundleURL: URL, icon: NSImage, label: String) {
    self.bundleURL = bundleURL
    self.icon = icon
    self.label = label
    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerCurve = .continuous
    toolTip = "Drag \(label) to System Settings"
    setAccessibilityElement(true)
    setAccessibilityLabel("\(label) drag item")
    setAccessibilityHelp(
      "Use a pointer to drag this app into the Accessibility application list."
    )
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 126, height: 34)
  }

  func configure(bundleURL: URL, icon: NSImage, label: String) {
    self.bundleURL = bundleURL
    self.icon = icon
    self.label = label
    toolTip = "Drag \(label) to System Settings"
    setAccessibilityLabel("\(label) drag item")
    needsDisplay = true
    invalidateIntrinsicContentSize()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func mouseDragged(with event: NSEvent) {
    guard !dragStarted else { return }
    dragStarted = true

    let draggingItem = NSDraggingItem(
      pasteboardWriter: bundleURL as NSURL
    )
    draggingItem.setDraggingFrame(bounds, contents: dragImage())
    let session = beginDraggingSession(
      with: [draggingItem],
      event: event,
      source: self
    )
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  override func mouseUp(with event: NSEvent) {
    dragStarted = false
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    dragStarted = false
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawChip(in: bounds)
  }

  private func dragImage() -> NSImage {
    guard
      bounds.width > 1,
      bounds.height > 1,
      let representation = bitmapImageRepForCachingDisplay(in: bounds)
    else {
      return icon
    }

    cacheDisplay(in: bounds, to: representation)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(representation)
    return image
  }

  private func drawChip(in rect: NSRect) {
    let isDark =
      effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
      == .darkAqua
    let chipRect = rect.insetBy(dx: 1, dy: 1)
    let chipPath = NSBezierPath(
      roundedRect: chipRect,
      xRadius: chipRect.height / 2,
      yRadius: chipRect.height / 2
    )

    (isDark
      ? NSColor.white.withAlphaComponent(0.10)
      : NSColor.white.withAlphaComponent(0.78)).setFill()
    chipPath.fill()

    (isDark
      ? NSColor.white.withAlphaComponent(0.16)
      : NSColor.black.withAlphaComponent(0.09)).setStroke()
    chipPath.lineWidth = 1
    chipPath.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: isDark
        ? NSColor.white.withAlphaComponent(0.92)
        : NSColor.black.withAlphaComponent(0.80),
      .paragraphStyle: paragraph,
    ]
    let iconSize: CGFloat = 20
    let iconLabelGap: CGFloat = 7
    let horizontalPadding: CGFloat = 8
    let maxLabelWidth = max(
      0,
      chipRect.width
        - horizontalPadding * 2
        - iconSize
        - iconLabelGap
    )
    let measuredLabelSize = (label as NSString).size(
      withAttributes: labelAttributes
    )
    let labelWidth = min(
      ceil(measuredLabelSize.width),
      maxLabelWidth
    )
    let labelHeight = ceil(measuredLabelSize.height)
    let contentWidth = iconSize + iconLabelGap + labelWidth
    let contentOriginX = chipRect.midX - contentWidth / 2
    let iconRect = NSRect(
      x: contentOriginX,
      y: chipRect.midY - iconSize / 2,
      width: iconSize,
      height: iconSize
    )
    icon.draw(
      in: iconRect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )

    let labelRect = NSRect(
      x: iconRect.maxX + iconLabelGap,
      y: chipRect.midY - labelHeight / 2,
      width: labelWidth,
      height: labelHeight
    )
    (label as NSString).draw(
      in: labelRect,
      withAttributes: labelAttributes
    )
  }
}
