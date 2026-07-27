import DeskHelmAppCore
import Foundation
import Testing

@testable import DeskHelmMac

@Suite("Volume-key controller", .serialized)
struct VolumeKeyControllerTests {
  @Test("The controller forwards full target events and cancels off route")
  @MainActor
  func forwardsEventsAndCancelsOffRoute() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let hud = StubVolumeHUD()
    let feedback = StubFeedbackCoordinator()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { onEvent, onDisabled in
        monitor.configure(onEvent: onEvent, onDisabled: onDisabled)
        return monitor
      },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      hud: hud,
      feedbackCoordinator: feedback
    )

    controller.setEnabled(true)
    await waitForEnabled(state)

    let press = VolumeMediaKeyEvent(
      action: .increase,
      state: .pressed,
      shouldInvertFeedback: true
    )
    monitor.send(press, targetDeviceUID: "LG-UID")

    #expect(store.draftLevel == 25)
    #expect(hud.levels == [25])
    #expect(
      feedback.presses == [
        FeedbackPress(
          event: press,
          deviceUID: "LG-UID",
          targetLevel: 25,
          maximumLevel: 100
        )
      ]
    )

    let release = VolumeMediaKeyEvent(
      action: .increase,
      state: .released,
      shouldInvertFeedback: true
    )
    monitor.send(release, targetDeviceUID: "LG-UID")
    #expect(
      feedback.releases == [
        FeedbackRelease(event: release, deviceUID: "LG-UID")
      ]
    )

    monitor.send(press, targetDeviceUID: nil)
    #expect(feedback.cancelCount == 1)
    #expect(hud.invalidationCount == 1)

    controller.invalidate()
  }

  @Test("A display failure preserves the requested volume-key control")
  @MainActor
  func displayFailurePreservesRequest() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let hud = StubVolumeHUD()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      hud: hud,
      displayReadRetryDelays: [.zero],
      automaticRecoveryDelay: .zero
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    store.communicationFailureHandler?("The display connection changed.")

    #expect(state.isRequested)
    #expect(!state.isEnabled)
    #expect(defaults.bool(forKey: preferenceKey))
    #expect(!monitor.isRunning)
    #expect(displayMonitor.isRunning)

    await waitForEnabled(state)
    #expect(await display.readCount() == 2)
    #expect(monitor.startCount == 2)
    #expect(monitor.isRunning)

    controller.invalidate()
  }

  @Test("Display reconfiguration rearms a requested monitor with a fresh read")
  @MainActor
  func displayReconfigurationRearmsRequestedMonitor() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(
      readGate: readGate,
      failedReadNumbers: [2]
    )
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let hud = StubVolumeHUD()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      hud: hud,
      displayReadRetryDelays: [.zero, .zero],
      automaticRecoveryDelay: .zero
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    displayMonitor.send(.began)

    #expect(state.isRequested)
    #expect(!state.isEnabled)
    #expect(!monitor.isRunning)
    #expect(defaults.bool(forKey: preferenceKey))

    await store.refresh()
    #expect(await display.readCount() == 1)

    displayMonitor.send(.settled)
    await waitForEnabled(state)

    #expect(await display.readCount() == 3)
    #expect(await display.resetCount() == 1)
    #expect(
      await display.operations()
        == [.read(1), .reset, .read(2), .read(3)]
    )
    #expect(monitor.startCount == 2)
    #expect(monitor.isRunning)
    #expect(displayMonitor.isRunning)
    #expect(defaults.bool(forKey: preferenceKey))

    controller.invalidate()
  }

  @Test("Display reconfiguration cancels a queued volume write")
  @MainActor
  func displayReconfigurationCancelsQueuedWrite() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { onEvent, onDisabled in
        monitor.configure(onEvent: onEvent, onDisabled: onDisabled)
        return monitor
      },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      feedbackCoordinator: StubFeedbackCoordinator()
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    monitor.send(
      VolumeMediaKeyEvent(
        action: .increase,
        state: .pressed,
        shouldInvertFeedback: false
      ),
      targetDeviceUID: "LG-UID"
    )
    displayMonitor.send(.began)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(await display.writeCount() == 0)
    #expect(await display.readCount() == 1)
    #expect(!store.isBusy)

    controller.invalidate()
  }

  @Test("Session reset waits for an in-flight display write")
  @MainActor
  func sessionResetWaitsForInFlightWrite() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    let writeGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(
      readGate: readGate,
      writeGate: writeGate
    )
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { onEvent, onDisabled in
        monitor.configure(onEvent: onEvent, onDisabled: onDisabled)
        return monitor
      },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      feedbackCoordinator: StubFeedbackCoordinator()
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    monitor.send(
      VolumeMediaKeyEvent(
        action: .increase,
        state: .pressed,
        shouldInvertFeedback: false
      ),
      targetDeviceUID: "LG-UID"
    )
    await waitForWriteCount(1, display: display)

    displayMonitor.send(.began)
    for _ in 0..<20 {
      await Task.yield()
    }
    #expect(await display.resetCount() == 0)

    await writeGate.open()
    await waitForReset(display)

    #expect(
      await display.operations()
        == [.read(1), .write(25), .reset]
    )
    #expect(store.confirmedLevel == nil)
    #expect(!store.isBusy)

    controller.invalidate()
  }

  @Test("A pre-reconfiguration read cannot restore stale display state")
  @MainActor
  func staleReadCannotRestoreDisplayState() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    let staleReadGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(
      readGate: readGate,
      readGates: [2: staleReadGate]
    )
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      displayReadRetryDelays: [.zero]
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    let staleRefresh = Task { @MainActor in
      await store.refresh()
    }
    await waitForReadCount(2, display: display)

    displayMonitor.send(.began)
    await staleReadGate.open()
    _ = await staleRefresh.value

    #expect(store.confirmedLevel == nil)
    #expect(!store.isAdjustable)
    #expect(state.isRequested)
    #expect(!state.isEnabled)

    displayMonitor.send(.settled)
    await waitForEnabled(state)
    #expect(await display.readCount() == 3)
    #expect(await display.resetCount() == 1)

    controller.invalidate()
  }

  @Test("Disabling during reconfiguration keeps the store gated until settle")
  @MainActor
  func disableDuringReconfigurationKeepsStoreGated() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      }
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    displayMonitor.send(.began)
    controller.setEnabled(false)

    let preSettleRefresh = await store.refresh()
    #expect(preSettleRefresh == .skipped)
    #expect(await display.readCount() == 1)
    #expect(displayMonitor.isRunning)
    #expect(state.phase == .disabled)

    displayMonitor.send(.settled)
    let postSettleRefresh = await store.refresh()
    #expect(postSettleRefresh == .confirmed)
    #expect(await display.readCount() == 2)
    #expect(state.phase == .disabled)
    #expect(!monitor.isRunning)

    controller.invalidate()
  }

  @Test("Re-enabling during a disabled reconfiguration waits for settle")
  @MainActor
  func reenableDuringDisabledReconfigurationWaitsForSettle() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(
      readGate: readGate,
      failedReadNumbers: [2]
    )
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      displayReadRetryDelays: [.zero, .milliseconds(50)]
    )

    controller.setEnabled(true)
    await waitForEnabled(state)
    controller.setEnabled(false)
    displayMonitor.send(.began)
    controller.setEnabled(true)
    await waitForReset(display)
    try? await Task.sleep(for: .milliseconds(5))

    #expect(await display.readCount() == 1)
    #expect(monitor.startCount == 1)
    #expect(!monitor.isRunning)

    displayMonitor.send(.settled)
    await waitForEnabled(state)

    #expect(
      await display.operations()
        == [.read(1), .reset, .read(2), .read(3)]
    )
    #expect(monitor.startCount == 2)
    #expect(monitor.isRunning)

    controller.invalidate()
  }

  @Test("Settled recovery preserves a manual permission prompt")
  @MainActor
  func settledRecoveryPreservesManualPermissionPrompt() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    permission.isGranted = false
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      displayReadRetryDelays: [.zero, .milliseconds(50)]
    )

    displayMonitor.send(.began)
    controller.setEnabled(true)
    try? await Task.sleep(for: .milliseconds(5))
    #expect(state.phase == .enabling)
    #expect(permission.promptCount == 0)

    displayMonitor.send(.settled)
    await waitForEnabled(state)

    #expect(permission.promptCount == 1)
    #expect(permission.isGranted)
    #expect(monitor.isRunning)
    #expect(defaults.bool(forKey: preferenceKey))

    controller.invalidate()
  }

  @Test("Disabling during display refresh cannot enable the monitor")
  @MainActor
  func disableCancelsRefreshCompletion() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let hud = StubVolumeHUD()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      },
      hud: hud
    )

    controller.setEnabled(true)
    await waitForRead(display)
    #expect(state.phase == .enabling)

    controller.setEnabled(false)
    displayMonitor.send(.settled)
    await readGate.open()
    await waitForRefreshToSettle(store)

    #expect(state.phase == .disabled)
    #expect(!defaults.bool(forKey: preferenceKey))
    #expect(monitor.startCount == 0)
    #expect(!monitor.isRunning)
  }

  @Test("A legacy disabled preference needs one manual enable")
  @MainActor
  func legacyDisabledPreferenceNeedsManualEnable() async {
    let defaults = UserDefaults.standard
    let preferenceKey = "VolumeKeysRequested"
    let originalPreference = defaults.object(forKey: preferenceKey)
    defer {
      if let originalPreference {
        defaults.set(originalPreference, forKey: preferenceKey)
      } else {
        defaults.removeObject(forKey: preferenceKey)
      }
    }

    defaults.set(false, forKey: preferenceKey)
    let readGate = AsyncGate()
    await readGate.open()
    let display = StubVolumeController(readGate: readGate)
    let store = VolumeStore(controller: display)
    let state = VolumeKeyFeatureState()
    let permission = StubAccessibilityPermission()
    let monitor = StubMediaKeyMonitor()
    let displayMonitor = StubDisplayReconfigurationMonitor()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      displayReconfigurationMonitorFactory: { onEvent in
        displayMonitor.configure(onEvent: onEvent)
        return displayMonitor
      }
    )

    controller.restoreIfRequested()
    #expect(state.phase == .disabled)
    #expect(monitor.startCount == 0)
    #expect(displayMonitor.startCount == 1)

    controller.setEnabled(true)
    await waitForEnabled(state)
    #expect(monitor.startCount == 1)
    #expect(displayMonitor.startCount == 1)

    controller.invalidate()
  }

  @MainActor
  private func waitForRead(_ display: StubVolumeController) async {
    await waitForReadCount(1, display: display)
  }

  @MainActor
  private func waitForReadCount(
    _ count: Int,
    display: StubVolumeController
  ) async {
    for _ in 0..<500 {
      if await display.readCount() == count {
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for the display read.")
  }

  @MainActor
  private func waitForRefreshToSettle(_ store: VolumeStore) async {
    for _ in 0..<500 {
      if !store.isBusy {
        await Task.yield()
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for the canceled refresh to settle.")
  }

  @MainActor
  private func waitForWriteCount(
    _ count: Int,
    display: StubVolumeController
  ) async {
    for _ in 0..<500 {
      if await display.writeCount() == count {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for the display write.")
  }

  @MainActor
  private func waitForReset(_ display: StubVolumeController) async {
    for _ in 0..<500 {
      if await display.resetCount() == 1, !Task.isCancelled {
        await Task.yield()
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for the display session reset.")
  }

  @MainActor
  private func waitForEnabled(_ state: VolumeKeyFeatureState) async {
    for _ in 0..<500 {
      if state.phase == .enabled {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for volume keys to become enabled.")
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

private actor StubVolumeController: VolumeControlling {
  private let readGate: AsyncGate
  private let readGates: [Int: AsyncGate]
  private let writeGate: AsyncGate?
  private let failedReadNumbers: Set<Int>
  private var reads = 0
  private var writes = 0
  private var resets = 0
  private var operationLog: [StubVolumeControllerOperation] = []

  init(
    readGate: AsyncGate,
    readGates: [Int: AsyncGate] = [:],
    writeGate: AsyncGate? = nil,
    failedReadNumbers: Set<Int> = []
  ) {
    self.readGate = readGate
    self.readGates = readGates
    self.writeGate = writeGate
    self.failedReadNumbers = failedReadNumbers
  }

  func readVolume() async throws -> VolumeReading {
    reads += 1
    let readNumber = reads
    operationLog.append(.read(readNumber))
    if let perReadGate = readGates[readNumber] {
      await perReadGate.wait()
    } else {
      await readGate.wait()
    }
    if failedReadNumbers.contains(readNumber) {
      throw StubVolumeControllerError.readFailed
    }
    return VolumeReading(
      display: "LG 39GX950B",
      current: 24,
      maximum: 100
    )
  }

  func writeVolume(to level: Int) async throws {
    writes += 1
    operationLog.append(.write(level))
    if let writeGate {
      await writeGate.wait()
    }
  }

  func setVolume(to level: Int) async throws -> VolumeReading {
    VolumeReading(
      display: "LG 39GX950B",
      current: level,
      maximum: 100
    )
  }

  func readCount() -> Int {
    reads
  }

  func resetConnection() async {
    resets += 1
    operationLog.append(.reset)
  }

  func resetCount() -> Int {
    resets
  }

  func writeCount() -> Int {
    writes
  }

  func operations() -> [StubVolumeControllerOperation] {
    operationLog
  }
}

private enum StubVolumeControllerOperation: Equatable {
  case read(Int)
  case write(Int)
  case reset
}

private enum StubVolumeControllerError: Error {
  case readFailed
}

@MainActor
private final class StubAccessibilityPermission:
  VolumeKeyAccessibilityProviding
{
  var isGranted = true
  private(set) var promptCount = 0

  func request(prompt: Bool) -> AccessibilityPermissionState {
    if prompt {
      promptCount += 1
      isGranted = true
    }
    return isGranted ? .granted : .required
  }

  func refresh() -> AccessibilityPermissionState {
    isGranted ? .granted : .required
  }
}

@MainActor
private final class StubMediaKeyMonitor: VolumeKeyMonitoring {
  private(set) var isRunning = false
  private(set) var startCount = 0
  private var onEvent: ((VolumeMediaKeyEvent, String?) -> Void)?
  private var onDisabled: ((String) -> Void)?

  func configure(
    onEvent: @escaping (VolumeMediaKeyEvent, String?) -> Void,
    onDisabled: @escaping (String) -> Void
  ) {
    self.onEvent = onEvent
    self.onDisabled = onDisabled
  }

  func start() throws {
    startCount += 1
    isRunning = true
  }

  func stop() {
    isRunning = false
  }

  func send(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String?
  ) {
    onEvent?(event, targetDeviceUID)
  }
}

@MainActor
private final class StubDisplayReconfigurationMonitor:
  DisplayReconfigurationMonitoring
{
  private(set) var isRunning = false
  private(set) var startCount = 0
  private var onEvent: ((DisplayReconfigurationEvent) -> Void)?

  func configure(
    onEvent: @escaping (DisplayReconfigurationEvent) -> Void
  ) {
    self.onEvent = onEvent
  }

  func start() throws {
    startCount += 1
    isRunning = true
  }

  func stop() {
    isRunning = false
  }

  func send(_ event: DisplayReconfigurationEvent) {
    onEvent?(event)
  }
}

@MainActor
private final class StubVolumeHUD: VolumeKeyHUDPresenting {
  private(set) var levels: [Int] = []
  private(set) var invalidationCount = 0

  func show(level: Int, updateUptime: TimeInterval) {
    levels.append(level)
  }

  func show(error message: String) {}

  func invalidate() {
    invalidationCount += 1
  }
}

@MainActor
private final class StubFeedbackCoordinator: VolumeFeedbackCoordinating {
  private(set) var presses: [FeedbackPress] = []
  private(set) var releases: [FeedbackRelease] = []
  private(set) var cancelCount = 0

  func observePress(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String,
    targetLevel: Int,
    maximumLevel: Int
  ) {
    presses.append(
      FeedbackPress(
        event: event,
        deviceUID: targetDeviceUID,
        targetLevel: targetLevel,
        maximumLevel: maximumLevel
      )
    )
  }

  func observeRelease(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  ) {
    releases.append(
      FeedbackRelease(event: event, deviceUID: targetDeviceUID)
    )
  }

  func cancel() {
    cancelCount += 1
  }
}

private struct FeedbackPress: Equatable {
  let event: VolumeMediaKeyEvent
  let deviceUID: String
  let targetLevel: Int
  let maximumLevel: Int
}

private struct FeedbackRelease: Equatable {
  let event: VolumeMediaKeyEvent
  let deviceUID: String
}
