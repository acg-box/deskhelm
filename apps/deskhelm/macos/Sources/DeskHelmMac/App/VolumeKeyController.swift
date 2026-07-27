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
  typealias DisplayReconfigurationMonitorFactory = (
    @escaping @MainActor (DisplayReconfigurationEvent) -> Void
  ) -> any DisplayReconfigurationMonitoring

  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "VolumeKeys"
  )
  private let store: VolumeStore
  private let state: VolumeKeyFeatureState
  private let accessibilityPermission: any VolumeKeyAccessibilityProviding
  private let monitorFactory: MonitorFactory
  private let displayReconfigurationMonitorFactory: DisplayReconfigurationMonitorFactory
  private let hud: any VolumeKeyHUDPresenting
  private let feedbackCoordinator: any VolumeFeedbackCoordinating
  private let displayReadRetryDelays: [Duration]
  private let automaticRecoveryDelay: Duration
  private var enableRequestState = VolumeKeyEnableRequestState()
  private var enableTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var isDisplayObservationStarted = false
  private var shouldRequestPermissionOnNextEnable = false
  private var shouldPresentHUD: @MainActor () -> Bool = { true }
  private var lastLevelUpdateUptime: TimeInterval?
  private lazy var monitor = monitorFactory(
    { [weak self] event, targetDeviceUID in
      self?.receive(event, targetDeviceUID: targetDeviceUID)
    },
    { [weak self] message in
      guard self?.state.isEnabled == true else { return }
      self?.suspendForUnavailable(message, scheduleRecovery: true)
    }
  )
  private lazy var displayReconfigurationMonitor =
    displayReconfigurationMonitorFactory { [weak self] event in
      self?.receiveDisplayReconfiguration(event)
    }

  init(
    store: VolumeStore,
    state: VolumeKeyFeatureState,
    accessibilityPermission: any VolumeKeyAccessibilityProviding,
    monitorFactory: @escaping MonitorFactory = {
      MediaKeyMonitor(onEvent: $0, onDisabled: $1)
    },
    displayReconfigurationMonitorFactory:
      @escaping DisplayReconfigurationMonitorFactory = {
        DisplayReconfigurationMonitor(onEvent: $0)
      },
    hud: any VolumeKeyHUDPresenting = VolumeHUDController(),
    feedbackCoordinator: (any VolumeFeedbackCoordinating)? = nil,
    displayReadRetryDelays: [Duration] = [
      .zero,
      .milliseconds(250),
      .milliseconds(500),
      .seconds(1),
      .seconds(2),
      .seconds(4),
    ],
    automaticRecoveryDelay: Duration = .milliseconds(750)
  ) {
    self.store = store
    self.state = state
    self.accessibilityPermission = accessibilityPermission
    self.monitorFactory = monitorFactory
    self.displayReconfigurationMonitorFactory =
      displayReconfigurationMonitorFactory
    self.hud = hud
    self.feedbackCoordinator =
      feedbackCoordinator ?? VolumeFeedbackCoordinator(store: store)
    self.displayReadRetryDelays =
      displayReadRetryDelays.isEmpty ? [.zero] : displayReadRetryDelays
    self.automaticRecoveryDelay = automaticRecoveryDelay
    store.communicationFailureHandler = { [weak self] message in
      guard self?.state.isEnabled == true else { return }
      self?.suspendForUnavailable(message, scheduleRecovery: true)
    }
    do {
      try startDisplayObservation()
    } catch {
      logger.error(
        "Display reconfiguration observation was not available at startup: \(error.localizedDescription, privacy: .public)"
      )
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
    cancelRecovery()
    feedbackCoordinator.cancel()
    monitor.stop()
    displayReconfigurationMonitor.stop()
    isDisplayObservationStarted = false
    shouldRequestPermissionOnNextEnable = false
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

    do {
      try startDisplayObservation()
    } catch {
      failAndDisable(error.localizedDescription)
      return
    }

    if requestPermission {
      shouldRequestPermissionOnNextEnable = true
    }
    UserDefaults.standard.set(true, forKey: Self.preferenceKey)
    state.update(to: .enabling)
    let token = enableRequestState.begin()
    enableTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await enable(token: token)
      guard enableRequestState.finish(token) else { return }
      enableTask = nil
    }
  }

  private func enable(token: VolumeKeyEnableRequestState.Token) async {
    let displayIsReady = await ensureDisplayIsReady()
    guard isCurrentEnable(token) else { return }

    guard displayIsReady else {
      let message =
        store.errorMessage
        ?? "DeskHelm could not read the display before enabling volume keys."
      suspendForUnavailable(message, scheduleRecovery: false)
      return
    }

    if !accessibilityPermission.isGranted,
      shouldRequestPermissionOnNextEnable
    {
      accessibilityPermission.request(prompt: true)
    }

    guard isCurrentEnable(token) else { return }
    guard accessibilityPermission.refresh() == .granted else {
      cancelRecovery()
      shouldRequestPermissionOnNextEnable = false
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
      shouldRequestPermissionOnNextEnable = false
      cancelRecovery()
      logger.notice("Keyboard volume control enabled.")
    } catch {
      failAndDisable(error.localizedDescription)
    }
  }

  private func disable() {
    cancelPendingEnable()
    cancelRecovery()
    shouldRequestPermissionOnNextEnable = false
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
    for delay in displayReadRetryDelays {
      if delay != .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return false
        }
      }

      await store.waitUntilIdle()
      guard !Task.isCancelled else { return false }
      let result = await store.refresh()
      if result == .confirmed,
        store.confirmedLevel != nil,
        store.errorMessage == nil
      {
        return true
      }
    }

    return false
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
      suspendForUnavailable(
        "DeskHelm lost the confirmed display volume.",
        scheduleRecovery: true
      )
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

  private func receiveDisplayReconfiguration(
    _ event: DisplayReconfigurationEvent
  ) {
    switch event {
    case .began:
      store.displayConnectionWillReconfigure()
    case .settled:
      store.displayConnectionDidSettle()
    }
    guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else {
      return
    }

    switch event {
    case .began:
      cancelRecovery()
      hud.invalidate()
      suspendForUnavailable(
        "Waiting for the display connection to settle…",
        scheduleRecovery: false,
        showHUD: false
      )
    case .settled:
      cancelPendingEnable()
      scheduleRecovery(after: .zero)
    }
  }

  private func suspendForUnavailable(
    _ message: String,
    scheduleRecovery: Bool,
    showHUD: Bool = true
  ) {
    cancelPendingEnable()
    feedbackCoordinator.cancel()
    monitor.stop()
    lastLevelUpdateUptime = nil
    UserDefaults.standard.set(true, forKey: Self.preferenceKey)
    state.update(to: .unavailable(message))
    if showHUD && shouldPresentHUD() {
      hud.show(error: message)
    }
    logger.error(
      "Keyboard volume control suspended: \(message, privacy: .public)"
    )

    if scheduleRecovery {
      self.scheduleRecovery(after: automaticRecoveryDelay)
    }
  }

  private func scheduleRecovery(after delay: Duration) {
    cancelRecovery()
    recoveryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if delay != .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
      guard
        !Task.isCancelled,
        UserDefaults.standard.bool(forKey: Self.preferenceKey)
      else {
        return
      }

      recoveryTask = nil
      requestEnable(requestPermission: false)
    }
  }

  private func cancelRecovery() {
    recoveryTask?.cancel()
    recoveryTask = nil
  }

  private func startDisplayObservation() throws {
    guard !isDisplayObservationStarted else { return }

    try displayReconfigurationMonitor.start()
    isDisplayObservationStarted = true
  }

  private func failAndDisable(_ message: String) {
    cancelPendingEnable()
    cancelRecovery()
    shouldRequestPermissionOnNextEnable = false
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
