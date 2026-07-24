import AppKit
import DeskHelmAppCore
import SwiftUI

@MainActor
final class VolumeHUDController {
  private let panel: VolumeHUDPanel
  private let state: VolumeHUDState
  private let hostingView: NonOpaqueHostingView
  private var dismissalTask: Task<Void, Never>?
  private var presentationGeneration = 0
  private var lastLevelUpdateUptime: TimeInterval?

  init() {
    let state = VolumeHUDState()

    self.state = state
    hostingView = NonOpaqueHostingView(
      rootView: AnyView(
        VolumeHUD(state: state)
          .environment(\.appearsActive, true)
      )
    )
    panel = VolumeHUDPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    configurePanel()
  }

  func show(
    level: Int,
    updateUptime: TimeInterval
  ) {
    let level = min(max(level, 0), 100)
    let content = VolumeHUDContent.level(level)
    let requiresLayout = requiresLayout(for: content)
    let animationPlan = VolumeLevelAnimationPolicy.plan(
      previousUpdateUptime: lastLevelUpdateUptime,
      currentUpdateUptime: updateUptime,
      isVisible: panel.isVisible,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    lastLevelUpdateUptime = updateUptime
    updateContent(content, animationPlan: animationPlan)
    present(
      for: .seconds(1.25),
      phase: "level-\(level)",
      requiresLayout: requiresLayout
    )
  }

  func show(error message: String) {
    let content = VolumeHUDContent.message(message)
    lastLevelUpdateUptime = nil
    updateContent(content, animationPlan: .immediate)
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
    lastLevelUpdateUptime = nil
  }

  private func configurePanel() {
    panel.contentView = hostingView
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
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
      hostingView.layoutSubtreeIfNeeded()
      let size = hostingView.fittingSize

      panel.setContentSize(size)
      positionPanel()
    }
    if !wasVisible {
      panel.orderFrontRegardless()
    }
    if !panel.isKeyWindow {
      panel.makeKey()
    }
    panel.alphaValue = 1
    panel.displayIfNeeded()
    if !wasVisible {
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

  private func updateContent(
    _ newContent: VolumeHUDContent,
    animationPlan: VolumeLevelAnimationPlan
  ) {
    guard newContent != state.content else { return }

    animationPlan.perform {
      applyContent(newContent)
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
      + "surface=swiftui-clear-glass-single-tree "
      + "windowNumber=\(panel.windowNumber) "
      + "x=\(Int(panel.frame.minX.rounded())) y=\(Int(panel.frame.minY.rounded())) "
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
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
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

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
