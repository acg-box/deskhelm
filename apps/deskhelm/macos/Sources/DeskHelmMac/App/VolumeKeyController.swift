import AppKit
import DeskHelmAppCore
import OSLog
import SwiftUI

@MainActor
protocol VolumeKeyAccessibilityProviding: AnyObject {
  var isGranted: Bool { get }
  @discardableResult
  func request(prompt: Bool) -> AccessibilityPermissionState
  @discardableResult
  func refresh() -> AccessibilityPermissionState
}

@MainActor
protocol VolumeKeyMonitoring: AnyObject {
  var isRunning: Bool { get }
  func start() throws
  func stop()
}

@MainActor
protocol VolumeKeyHUDPresenting: AnyObject {
  func show(level: Int, updateUptime: TimeInterval)
  func show(error message: String)
  func invalidate()
}

@MainActor
final class VolumeKeyController {
  typealias MonitorFactory = (
    @escaping (VolumeMediaKeyEvent, String?) -> Void,
    @escaping (String) -> Void
  ) -> any VolumeKeyMonitoring

  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "VolumeKeys"
  )
  private let store: VolumeStore
  private let state: VolumeKeyFeatureState
  private let accessibilityPermission: any VolumeKeyAccessibilityProviding
  private let monitorFactory: MonitorFactory
  private let hud: any VolumeKeyHUDPresenting
  private let feedbackCoordinator: any VolumeFeedbackCoordinating
  private var enableRequestState = VolumeKeyEnableRequestState()
  private var enableTask: Task<Void, Never>?
  private var shouldPresentHUD: @MainActor () -> Bool = { true }
  private var lastLevelUpdateUptime: TimeInterval?
  private lazy var monitor = monitorFactory(
    { [weak self] event, targetDeviceUID in
      self?.receive(event, targetDeviceUID: targetDeviceUID)
    },
    { [weak self] message in
      guard self?.state.isEnabled == true else { return }
      self?.fail(message)
    }
  )

  init(
    store: VolumeStore,
    state: VolumeKeyFeatureState,
    accessibilityPermission: any VolumeKeyAccessibilityProviding,
    monitorFactory: @escaping MonitorFactory = {
      MediaKeyMonitor(onEvent: $0, onDisabled: $1)
    },
    hud: any VolumeKeyHUDPresenting = VolumeHUDController(),
    feedbackCoordinator: (any VolumeFeedbackCoordinating)? = nil
  ) {
    self.store = store
    self.state = state
    self.accessibilityPermission = accessibilityPermission
    self.monitorFactory = monitorFactory
    self.hud = hud
    self.feedbackCoordinator =
      feedbackCoordinator ?? VolumeFeedbackCoordinator(store: store)
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

    requestEnable(requestPermission: false)
  }

  func setEnabled(_ isEnabled: Bool) {
    if !isEnabled {
      disable()
      return
    }

    requestEnable(requestPermission: true)
  }

  func setHUDPresentationPolicy(
    _ policy: @escaping @MainActor () -> Bool
  ) {
    shouldPresentHUD = policy
  }

  func dismissHUD() {
    hud.invalidate()
  }

  func invalidate() {
    cancelPendingEnable()
    feedbackCoordinator.cancel()
    monitor.stop()
    hud.invalidate()
    lastLevelUpdateUptime = nil
    store.communicationFailureHandler = nil
  }

  private func requestEnable(requestPermission: Bool) {
    guard
      !enableRequestState.hasActiveRequest,
      !monitor.isRunning,
      !state.isEnabled
    else {
      return
    }

    state.update(to: .enabling)
    let token = enableRequestState.begin()
    enableTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await enable(
        requestPermission: requestPermission,
        token: token
      )
      guard enableRequestState.finish(token) else { return }
      enableTask = nil
    }
  }

  private func enable(
    requestPermission: Bool,
    token: VolumeKeyEnableRequestState.Token
  ) async {
    let displayIsReady = await ensureDisplayIsReady()
    guard isCurrentEnable(token) else { return }

    guard displayIsReady else {
      let message =
        store.errorMessage
        ?? "DeskHelm could not read the display before enabling volume keys."
      fail(message)
      return
    }

    if !accessibilityPermission.isGranted, requestPermission {
      accessibilityPermission.request(prompt: true)
    }

    guard isCurrentEnable(token) else { return }
    guard accessibilityPermission.refresh() == .granted else {
      UserDefaults.standard.set(false, forKey: Self.preferenceKey)
      state.update(to: .permissionRequired)
      return
    }

    guard isCurrentEnable(token) else { return }
    do {
      try monitor.start()
      guard isCurrentEnable(token) else {
        monitor.stop()
        return
      }
      UserDefaults.standard.set(true, forKey: Self.preferenceKey)
      state.update(to: .enabled)
      logger.notice("Keyboard volume control enabled.")
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func disable() {
    cancelPendingEnable()
    feedbackCoordinator.cancel()
    monitor.stop()
    hud.invalidate()
    lastLevelUpdateUptime = nil
    UserDefaults.standard.set(false, forKey: Self.preferenceKey)
    state.update(to: .disabled)
    logger.notice("Keyboard volume control disabled.")
  }

  private func cancelPendingEnable() {
    enableRequestState.cancel()
    enableTask?.cancel()
    enableTask = nil
  }

  private func isCurrentEnable(
    _ token: VolumeKeyEnableRequestState.Token
  ) -> Bool {
    enableRequestState.isCurrent(token) && !Task.isCancelled
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

  private func receive(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String?
  ) {
    guard state.isEnabled else { return }

    guard let targetDeviceUID else {
      feedbackCoordinator.cancel()
      hud.invalidate()
      lastLevelUpdateUptime = nil
      return
    }

    switch event.state {
    case .pressed:
      receivePressed(event, targetDeviceUID: targetDeviceUID)
    case .released:
      receiveReleased(event, targetDeviceUID: targetDeviceUID)
    }
  }

  private func receivePressed(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  ) {
    guard store.confirmedLevel != nil else {
      fail("DeskHelm lost the confirmed display volume.")
      return
    }

    let baseline = Int(store.draftLevel.rounded())
    let target = VolumeKeyAdjustment.target(
      for: event.action,
      current: baseline,
      maximum: store.maximumLevel
    )
    let updateUptime = ProcessInfo.processInfo.systemUptime
    let animationPlan = VolumeLevelAnimationPolicy.plan(
      previousUpdateUptime: lastLevelUpdateUptime,
      currentUpdateUptime: updateUptime,
      isVisible: true,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      animatesFirstUpdate: true
    )
    lastLevelUpdateUptime = updateUptime
    animationPlan.perform {
      store.updateDraft(Double(target))
      store.queueDraftApply()
    }
    if shouldPresentHUD() {
      hud.show(level: target, updateUptime: updateUptime)
    }

    feedbackCoordinator.observePress(
      event,
      targetDeviceUID: targetDeviceUID,
      targetLevel: target,
      maximumLevel: store.maximumLevel
    )
  }

  private func receiveReleased(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  ) {
    feedbackCoordinator.observeRelease(
      event,
      targetDeviceUID: targetDeviceUID
    )
  }

  private func fail(_ message: String) {
    cancelPendingEnable()
    feedbackCoordinator.cancel()
    monitor.stop()
    lastLevelUpdateUptime = nil
    UserDefaults.standard.set(false, forKey: Self.preferenceKey)
    state.update(to: .failed(message))
    if shouldPresentHUD() {
      hud.show(error: message)
    }
    logger.error("Keyboard volume control stopped: \(message, privacy: .public)")
  }

  private static let preferenceKey = "VolumeKeysRequested"
}

extension AccessibilityPermission: VolumeKeyAccessibilityProviding {}
extension MediaKeyMonitor: VolumeKeyMonitoring {}
extension VolumeHUDController: VolumeKeyHUDPresenting {}
