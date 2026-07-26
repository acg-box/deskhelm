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
    let hud = StubVolumeHUD()
    let controller = VolumeKeyController(
      store: store,
      state: state,
      accessibilityPermission: permission,
      monitorFactory: { _, _ in monitor },
      hud: hud
    )

    controller.setEnabled(true)
    await waitForRead(display)
    #expect(state.phase == .enabling)

    controller.setEnabled(false)
    await readGate.open()
    await waitForRefreshToSettle(store)

    #expect(state.phase == .disabled)
    #expect(!defaults.bool(forKey: preferenceKey))
    #expect(monitor.startCount == 0)
    #expect(!monitor.isRunning)
  }

  @MainActor
  private func waitForRead(_ display: StubVolumeController) async {
    for _ in 0..<500 {
      if await display.readCount() == 1 {
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
  private func waitForEnabled(_ state: VolumeKeyFeatureState) async {
    for _ in 0..<500 {
      if state.phase == .enabled {
        return
      }
      await Task.yield()
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
  private var reads = 0

  init(readGate: AsyncGate) {
    self.readGate = readGate
  }

  func readVolume() async throws -> VolumeReading {
    reads += 1
    await readGate.wait()
    return VolumeReading(
      display: "LG 39GX950B",
      current: 24,
      maximum: 100
    )
  }

  func writeVolume(to level: Int) async throws {}

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
}

@MainActor
private final class StubAccessibilityPermission:
  VolumeKeyAccessibilityProviding
{
  var isGranted = true

  func request(prompt: Bool) -> AccessibilityPermissionState {
    .granted
  }

  func refresh() -> AccessibilityPermissionState {
    .granted
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
