import AppKit
import DeskHelmAppCore
import SwiftUI

@MainActor
final class VolumeHUDController {
  private let panel: VolumeHUDPanel
  private let state: VolumeHUDState
  private let surfaceView: VolumeHUDSurfaceView
  private var dismissalTask: Task<Void, Never>?
  private var presentationGeneration = 0

  init() {
    let state = VolumeHUDState()

    self.state = state
    surfaceView = VolumeHUDSurfaceView(state: state)
    panel = VolumeHUDPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    configurePanel()
  }

  func show(level: Int) {
    let level = min(max(level, 0), 100)
    let content = VolumeHUDContent.level(level)
    let requiresLayout = requiresLayout(for: content)
    updateContent(content)
    present(
      for: .seconds(1.25),
      phase: "level-\(level)",
      requiresLayout: requiresLayout
    )
  }

  func show(error message: String) {
    let content = VolumeHUDContent.message(message)
    updateContent(content)
    present(
      for: .seconds(2),
      phase: "error",
      requiresLayout: true
    )
  }

  func invalidate() {
    presentationGeneration += 1
    dismissalTask?.cancel()
    dismissalTask = nil
    panel.orderOut(nil)
    panel.alphaValue = 1
  }

  private func configurePanel() {
    panel.contentView = surfaceView
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .transient,
    ]
    panel.animationBehavior = .utilityWindow
  }

  private func present(
    for duration: Duration,
    phase: String,
    requiresLayout: Bool
  ) {
    presentationGeneration += 1
    let generation = presentationGeneration
    dismissalTask?.cancel()
    let wasVisible = panel.isVisible

    if !wasVisible || requiresLayout {
      surfaceView.layoutSubtreeIfNeeded()
      let size = surfaceView.contentFittingSize

      panel.setContentSize(size)
      positionPanel()
    }
    panel.alphaValue = 1
    if !wasVisible {
      panel.orderFrontRegardless()
      panel.displayIfNeeded()
      publishState(phase: phase)
    }

    dismissalTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: duration)
        guard let self else { return }
        try await self.fadeOut(generation: generation)
      } catch {
        return
      }
    }
  }

  private func updateContent(_ newContent: VolumeHUDContent) {
    guard newContent != state.content else { return }

    let shouldAnimate =
      panel.isVisible
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      && isLevelContent(state.content)
      && isLevelContent(newContent)

    if shouldAnimate {
      withAnimation(.smooth(duration: 0.16, extraBounce: 0)) {
        applyContent(newContent)
      }
    } else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        applyContent(newContent)
      }
    }
  }

  private func applyContent(_ content: VolumeHUDContent) {
    switch content {
    case .level(let level):
      state.show(level: level)
    case .message(let message):
      state.show(message: message)
    }
  }

  private func isLevelContent(_ content: VolumeHUDContent) -> Bool {
    if case .level = content {
      return true
    }

    return false
  }

  private func requiresLayout(for newContent: VolumeHUDContent) -> Bool {
    switch (state.content, newContent) {
    case (.level, .level):
      false
    case (.message, .message), (.level, .message), (.message, .level):
      true
    }
  }

  private func positionPanel() {
    let pointerLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(pointerLocation) }
      ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return }

    let x = visibleFrame.midX - panel.frame.width / 2
    let y = visibleFrame.minY + visibleFrame.height * 0.16
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func fadeOut(generation: Int) async throws {
    guard generation == presentationGeneration else { return }

    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let frameCount = 8
      for frame in 1...frameCount {
        try await Task.sleep(for: .milliseconds(20))
        guard generation == presentationGeneration else { return }
        panel.alphaValue = 1 - Double(frame) / Double(frameCount)
      }
    }

    guard generation == presentationGeneration else { return }
    panel.orderOut(nil)
    panel.alphaValue = 1
    dismissalTask = nil
    publishState(phase: "hidden")
  }

  private func publishState(phase: String) {
    let summary =
      "phase=\(phase) visible=\(panel.isVisible) key=\(panel.isKeyWindow) "
      + "active=\(NSApp.isActive) "
      + "nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)) "
      + "canBecomeKey=\(panel.canBecomeKey) "
      + "ignoresMouse=\(panel.ignoresMouseEvents) "
      + "surface=swiftui-clear-passive-sibling "
      + "width=\(Int(panel.frame.width.rounded())) height=\(Int(panel.frame.height.rounded()))"
    let defaults = UserDefaults.standard

    defaults.set(
      ProcessInfo.processInfo.processIdentifier,
      forKey: "VolumeHUDStatePID"
    )
    defaults.set(summary, forKey: "VolumeHUDStateSummary")
  }
}

@MainActor
private final class VolumeHUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class VolumeHUDSurfaceView: NSView {
  private let glassHostingView: NonOpaqueHostingView
  private let contentHostingView: NonOpaqueHostingView

  init(state: VolumeHUDState) {
    glassHostingView = NonOpaqueHostingView(
      rootView: AnyView(VolumeHUDGlassLayer())
    )
    contentHostingView = NonOpaqueHostingView(
      rootView: AnyView(
        VolumeHUDContentLayer(state: state)
          .padding(8)
          .environment(\.appearsActive, true)
      )
    )
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.isOpaque = false

    configure(hostingView: glassHostingView)
    configure(hostingView: contentHostingView)
    addSubview(glassHostingView)
    addSubview(contentHostingView, positioned: .above, relativeTo: glassHostingView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isOpaque: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    if glassHostingView.frame != bounds {
      glassHostingView.frame = bounds
    }
    if contentHostingView.frame != bounds {
      contentHostingView.frame = bounds
    }
  }

  var contentFittingSize: NSSize {
    contentHostingView.layoutSubtreeIfNeeded()
    return contentHostingView.fittingSize
  }

  private func configure(hostingView: NSView) {
    hostingView.frame = bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.layer?.isOpaque = false
  }
}

@MainActor
private final class NonOpaqueHostingView: NSHostingView<AnyView> {
  required init(rootView: AnyView) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isOpaque: Bool { false }
}

private struct VolumeHUDGlassLayer: View {
  var body: some View {
    Group {
      if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: 0) {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(
              .clear.interactive(false),
              in: Capsule()
            )
        }
      } else {
        Capsule()
          .fill(.regularMaterial)
      }
    }
    .padding(8)
    .environment(\.appearsActive, true)
    .allowsHitTesting(false)
  }
}
