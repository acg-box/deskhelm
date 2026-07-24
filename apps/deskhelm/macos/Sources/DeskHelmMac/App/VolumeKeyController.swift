import AppKit
import DeskHelmAppCore
import OSLog

@MainActor
final class VolumeKeyController {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "VolumeKeys"
  )
  private let store: VolumeStore
  private let state: VolumeKeyFeatureState
  private let hud: VolumeHUDController
  private lazy var monitor = MediaKeyMonitor(
    onAction: { [weak self] action in
      self?.receive(action)
    },
    onDisabled: { [weak self] message in
      guard self?.state.isEnabled == true else { return }
      self?.fail(message)
    }
  )

  init(
    store: VolumeStore,
    state: VolumeKeyFeatureState
  ) {
    self.store = store
    self.state = state
    self.hud = VolumeHUDController()
    store.communicationFailureHandler = { [weak self] message in
      guard self?.state.isEnabled == true else { return }
      self?.fail(message)
    }
  }

  func restoreIfRequested() {
    guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else {
      state.update(to: .disabled)
      return
    }

    Task { @MainActor [weak self] in
      await self?.enable(requestPermission: false)
    }
  }

  func toggle() {
    if monitor.isRunning || state.isEnabled {
      disable()
      return
    }

    guard
      MediaKeyMonitor.hasAccessibilityAccess
        || confirmAccessibilityRequest()
    else {
      return
    }

    Task { @MainActor [weak self] in
      await self?.enable(requestPermission: true)
    }
  }

  func invalidate() {
    monitor.stop()
    hud.invalidate()
    store.communicationFailureHandler = nil
  }

  private func enable(requestPermission: Bool) async {
    state.update(to: .enabling)

    guard await ensureDisplayIsReady() else {
      let message =
        store.errorMessage
        ?? "DeskHelm could not read the display before enabling volume keys."
      fail(message)
      return
    }

    if !MediaKeyMonitor.hasAccessibilityAccess, requestPermission {
      MediaKeyMonitor.requestAccessibilityAccess()
    }

    guard MediaKeyMonitor.hasAccessibilityAccess else {
      UserDefaults.standard.set(false, forKey: Self.preferenceKey)
      state.update(to: .permissionRequired)
      return
    }

    do {
      try monitor.start()
      UserDefaults.standard.set(true, forKey: Self.preferenceKey)
      state.update(to: .enabled)
      logger.notice("Keyboard volume control enabled.")
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func disable() {
    monitor.stop()
    hud.invalidate()
    UserDefaults.standard.set(false, forKey: Self.preferenceKey)
    state.update(to: .disabled)
    logger.notice("Keyboard volume control disabled.")
  }

  private func ensureDisplayIsReady() async -> Bool {
    for _ in 0..<40 {
      guard store.isBusy else { break }

      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return false
      }
    }

    guard !store.isBusy else { return false }
    await store.refresh()

    return store.confirmedLevel != nil && store.errorMessage == nil
  }

  private func receive(_ action: VolumeMediaKeyAction) {
    guard state.isEnabled else { return }
    guard store.confirmedLevel != nil else {
      fail("DeskHelm lost the confirmed display volume.")
      return
    }

    let baseline = Int(store.draftLevel.rounded())
    let target = VolumeKeyAdjustment.target(
      for: action,
      current: baseline,
      maximum: store.maximumLevel
    )
    store.updateDraft(Double(target))
    store.queueDraftApply()
    hud.show(level: target)
  }

  private func fail(_ message: String) {
    monitor.stop()
    UserDefaults.standard.set(false, forKey: Self.preferenceKey)
    state.update(to: .failed(message))
    hud.show(error: message)
    logger.error("Keyboard volume control stopped: \(message, privacy: .public)")
  }

  private func confirmAccessibilityRequest() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Enable Keyboard Volume Control?"
    alert.informativeText =
      "macOS requires Accessibility permission so DeskHelm can suppress its "
      + "disabled-volume response. DeskHelm consumes volume up and volume down "
      + "only while LG ULTRAGEAR+ is the current audio output. Other audio "
      + "routes keep normal macOS volume control. DeskHelm does not subscribe "
      + "to ordinary key presses, store input, or inspect other apps."
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    return alert.runModal() == .alertFirstButtonReturn
  }

  private static let preferenceKey = "VolumeKeysRequested"
}
