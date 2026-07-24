import AppKit
import DeskHelmAppCore
import OSLog
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "StatusItem"
  )
  private let statusItem: NSStatusItem
  private let panel: GlassPanel
  private let hostingController: PanelHostingController<VolumePanel>
  private let store: VolumeStore
  private let onPanelWillPresent: () -> Void
  private var presentationTask: Task<Void, Never>?
  private var dismissesOnResignKey = false

  var isPanelPresented: Bool {
    panel.isVisible || presentationTask != nil
  }

  var diagnosticSummary: String {
    let button = statusItem.button
    return
      "button=\(button != nil) image=\(button?.image != nil) "
      + "visible=\(statusItem.isVisible) window=\(button?.window?.isVisible == true) "
      + "titleEmpty=\(button?.title.isEmpty == true) panel=true"
  }

  init(
    store: VolumeStore,
    volumeKeyState: VolumeKeyFeatureState,
    onToggleVolumeKeys: @escaping () -> Void,
    onPanelWillPresent: @escaping () -> Void
  ) throws {
    self.store = store
    self.onPanelWillPresent = onPanelWillPresent
    self.statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )
    self.panel = GlassPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.hostingController = PanelHostingController(
      rootView: VolumePanel(
        store: store,
        volumeKeyState: volumeKeyState,
        onToggleVolumeKeys: onToggleVolumeKeys
      ) {
        NSApp.terminate(nil)
      }
    )

    super.init()

    guard let button = statusItem.button else {
      NSStatusBar.system.removeStatusItem(statusItem)
      throw StatusItemError.buttonUnavailable
    }

    guard let statusIcon = DeskHelmStatusIcon.makeImage() else {
      NSStatusBar.system.removeStatusItem(statusItem)
      throw StatusItemError.iconUnavailable
    }

    configureStatusButton(button, image: statusIcon)
    configurePanel()
    statusItem.isVisible = true

    logger.notice(
      "Created status item and glass panel: \(self.diagnosticSummary, privacy: .public)"
    )
  }

  func invalidate() {
    presentationTask?.cancel()
    presentationTask = nil
    panel.delegate = nil
    panel.orderOut(nil)
    hostingController.preferredSizeDidChange = nil
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  func showPanelForVerification() {
    guard
      !panel.isVisible,
      presentationTask == nil,
      let button = statusItem.button
    else {
      publishPanelState(phase: "verification-skipped")
      return
    }

    presentPanel(relativeTo: button)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard dismissesOnResignKey else { return }

    logger.debug("Glass panel resigned key status.")

    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !panel.isKeyWindow else { return }
      closePanel()
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    dismissesOnResignKey = true
  }

  private func configureStatusButton(
    _ button: NSStatusBarButton,
    image: NSImage
  ) {
    button.image = image
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.title = ""
    button.toolTip = "DeskHelm control deck"
    button.setAccessibilityLabel("DeskHelm display controls")
    button.target = self
    button.action = #selector(togglePanel(_:))
  }

  private func configurePanel() {
    hostingController.sizingOptions = [.preferredContentSize]
    hostingController.preferredSizeDidChange = { [weak self] size in
      self?.resizePanel(to: size)
    }
    hostingController.view.wantsLayer = true
    hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

    panel.contentViewController = hostingController
    panel.delegate = self
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.alphaValue = 1
    panel.level = .popUpMenu
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .transient,
    ]
    panel.animationBehavior = .utilityWindow
    panel.onCancel = { [weak self] in
      self?.closePanel()
    }
  }

  @objc
  private func togglePanel(_ sender: NSStatusBarButton) {
    logger.notice(
      "Status item pressed; panel visible=\(self.panel.isVisible) pending=\(self.presentationTask != nil)"
    )

    if panel.isVisible || presentationTask != nil {
      closePanel()
      return
    }

    presentPanel(relativeTo: sender)
  }

  private func presentPanel(relativeTo sender: NSStatusBarButton) {
    onPanelWillPresent()
    resizePanel(to: preferredPanelSize())
    positionPanel(relativeTo: sender)
    presentationTask = Task { @MainActor [weak self, weak sender] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }

      panel.orderFrontRegardless()
      panel.makeKey()
      panel.displayIfNeeded()
      dismissesOnResignKey = panel.isKeyWindow
      publishPanelState(phase: "shown")

      await store.refresh()
      guard !Task.isCancelled else { return }

      resizePanel(to: preferredPanelSize())
      if let button = sender ?? statusItem.button {
        positionPanel(relativeTo: button)
      }
      publishPanelState(phase: "refreshed")
      presentationTask = nil
    }
  }

  private func closePanel() {
    presentationTask?.cancel()
    presentationTask = nil
    dismissesOnResignKey = false
    panel.orderOut(nil)
    publishPanelState(phase: "closed")
  }

  private func preferredPanelSize() -> NSSize {
    hostingController.view.layoutSubtreeIfNeeded()

    let preferredSize = hostingController.preferredContentSize
    if preferredSize.width > 0, preferredSize.height > 0 {
      return preferredSize
    }

    return hostingController.view.fittingSize
  }

  private func resizePanel(to size: NSSize) {
    guard size.width > 0, size.height > 0 else { return }

    panel.setContentSize(size)

    if panel.isVisible, let button = statusItem.button {
      positionPanel(relativeTo: button)
    }
  }

  private func positionPanel(relativeTo button: NSStatusBarButton) {
    guard let buttonWindow = button.window else { return }

    let buttonFrameInWindow = button.convert(button.bounds, to: nil)
    let anchor = buttonWindow.convertToScreen(buttonFrameInWindow)
    let screen = buttonWindow.screen ?? NSScreen.main
    let availableFrame = screen?.visibleFrame ?? anchor
    let inset: CGFloat = 8
    let gap: CGFloat = 4

    let minimumX = availableFrame.minX + inset
    let maximumX = availableFrame.maxX - panel.frame.width - inset
    let centeredX = anchor.midX - panel.frame.width / 2
    let x = min(max(centeredX, minimumX), max(minimumX, maximumX))

    let belowY = anchor.minY - panel.frame.height - gap
    let aboveY = anchor.maxY + gap
    let preferredY =
      belowY >= availableFrame.minY + inset
      ? belowY
      : aboveY
    let minimumY = availableFrame.minY + inset
    let maximumY = availableFrame.maxY - panel.frame.height - inset
    let y = min(max(preferredY, minimumY), max(minimumY, maximumY))

    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func publishPanelState(phase: String) {
    let buttonScreen = statusItem.button?.window?.screen
    let visibleFrame = buttonScreen?.visibleFrame ?? panel.screen?.visibleFrame
    let isOnScreen = visibleFrame.map(panel.frame.intersects) ?? false
    let summary =
      "phase=\(phase) visible=\(panel.isVisible) key=\(panel.isKeyWindow) "
      + "active=\(NSApp.isActive) "
      + "nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)) "
      + "keyOnlyIfNeeded=\(panel.becomesKeyOnlyIfNeeded) "
      + "onScreen=\(isOnScreen) windowNumber=\(panel.windowNumber) "
      + "x=\(Int(panel.frame.minX.rounded())) y=\(Int(panel.frame.minY.rounded())) "
      + "width=\(Int(panel.frame.width.rounded())) height=\(Int(panel.frame.height.rounded()))"
    let defaults = UserDefaults.standard

    defaults.set(ProcessInfo.processInfo.processIdentifier, forKey: "PanelStatePID")
    defaults.set(summary, forKey: "PanelStateSummary")
    defaults.synchronize()
    logger.notice("panel-state \(summary, privacy: .public)")
  }
}

@MainActor
private final class GlassPanel: NSPanel {
  var onCancel: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

@MainActor
private final class PanelHostingController<Content: View>: NSHostingController<Content> {
  var preferredSizeDidChange: ((NSSize) -> Void)?

  override var preferredContentSize: NSSize {
    didSet {
      guard preferredContentSize != oldValue else { return }
      preferredSizeDidChange?(preferredContentSize)
    }
  }
}

private enum StatusItemError: LocalizedError {
  case buttonUnavailable
  case iconUnavailable

  var errorDescription: String? {
    switch self {
    case .buttonUnavailable:
      "macOS did not provide a button for the DeskHelm status item."
    case .iconUnavailable:
      "macOS does not provide the control-deck symbol used by DeskHelm."
    }
  }
}
