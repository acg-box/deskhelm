import DeskHelmAppCore
import Foundation
import Testing

@testable import DeskHelmMac

@Suite("Volume-key controller", .serialized)
struct VolumeKeyControllerTests {
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

  func start() throws {
    startCount += 1
    isRunning = true
  }

  func stop() {
    isRunning = false
  }
}

@MainActor
private final class StubVolumeHUD: VolumeKeyHUDPresenting {
  func show(level: Int, updateUptime: TimeInterval) {}
  func show(error message: String) {}
  func invalidate() {}
}
