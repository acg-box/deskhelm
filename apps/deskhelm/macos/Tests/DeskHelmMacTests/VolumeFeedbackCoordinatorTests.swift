import DeskHelmAppCore
import Foundation
import Testing

@testable import DeskHelmMac

@Suite("Volume feedback coordinator")
struct VolumeFeedbackCoordinatorTests {
  @Test("Release plays once after the final preview is accepted")
  @MainActor
  func releaseWaitsForPreviewAcceptance() async {
    let writeGate = FeedbackAsyncGate()
    let display = FeedbackVolumeController(writeGate: writeGate)
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let route = StubFeedbackRoute(deviceUID: "LG-UID")
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { route.deviceUID }
    )

    store.updateDraft(25)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 25,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )

    await waitForWrite(display)
    #expect(player.plays.isEmpty)

    await writeGate.open()
    await waitForPlay(player)

    #expect(
      player.plays == [
        FeedbackPlay(deviceUID: "LG-UID", invertsPreference: false)
      ]
    )
  }

  @Test("Rapid repeats produce one feedback sound for the final target")
  @MainActor
  func repeatsPlayOnlyFinalTarget() async {
    let display = FeedbackVolumeController()
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" }
    )

    for level in 25...29 {
      store.updateDraft(Double(level))
      store.queueDraftApply()
      coordinator.observePress(
        press(.increase),
        targetDeviceUID: "LG-UID",
        targetLevel: level,
        maximumLevel: 100
      )
    }
    coordinator.observeRelease(
      release(.increase, shouldInvertFeedback: true),
      targetDeviceUID: "LG-UID"
    )

    await waitForPlay(player)

    #expect(player.plays.count == 1)
    #expect(player.plays.first?.deviceUID == "LG-UID")
    #expect(player.plays.first?.invertsPreference == true)
    let writes = await display.writes()
    #expect(writes.last == 29)
  }

  @Test("A failed preview does not play feedback")
  @MainActor
  func failedPreviewStaysSilent() async {
    let display = FeedbackVolumeController(writeError: FeedbackTestError.write)
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" }
    )

    store.updateDraft(25)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 25,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )

    await waitForStoreToSettle(store)

    #expect(player.plays.isEmpty)
  }

  @Test("A route change while the final write is pending cancels feedback")
  @MainActor
  func routeChangeCancelsPendingFeedback() async {
    let writeGate = FeedbackAsyncGate()
    let display = FeedbackVolumeController(writeGate: writeGate)
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let route = StubFeedbackRoute(deviceUID: "LG-UID")
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { route.deviceUID }
    )

    store.updateDraft(25)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 25,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )
    await waitForWrite(display)

    route.deviceUID = "HEADPHONES"
    await writeGate.open()
    await waitForStoreToSettle(store)

    #expect(player.plays.isEmpty)
  }

  @Test("Maximum volume starts an immediate one-hertz boundary cue")
  @MainActor
  func maximumStartsBoundaryFeedback() async {
    let display = FeedbackVolumeController()
    let store = await readyStore(display: display, level: 99)
    let player = StubFeedbackPlayer()
    let uptime = StubFeedbackUptime()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" },
      uptimeProvider: { uptime.value },
      boundaryInterval: .milliseconds(10),
      boundaryWatchdog: 4
    )

    store.updateDraft(100)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 100,
      maximumLevel: 100
    )

    await waitForPlay(player, count: 2)
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )
    let countAfterRelease = player.plays.count
    try? await Task.sleep(for: .milliseconds(30))

    #expect(countAfterRelease >= 2)
    #expect(player.plays.count == countAfterRelease)
  }

  @Test("An already-maximum press cues without another display write")
  @MainActor
  func alreadyMaximumCuesWithoutWrite() async {
    let display = FeedbackVolumeController()
    let store = await readyStore(display: display, level: 100)
    let player = StubFeedbackPlayer()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" },
      boundaryInterval: .seconds(10)
    )

    store.updateDraft(100)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 100,
      maximumLevel: 100
    )

    await waitForPlay(player)
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )

    #expect(player.plays.count == 1)
    #expect(await display.writes().isEmpty)
  }

  @Test("A route change stops maximum-volume boundary feedback")
  @MainActor
  func routeChangeStopsBoundaryFeedback() async {
    let display = FeedbackVolumeController()
    let store = await readyStore(display: display, level: 100)
    let player = StubFeedbackPlayer()
    let route = StubFeedbackRoute(deviceUID: "LG-UID")
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { route.deviceUID },
      boundaryInterval: .milliseconds(10)
    )

    store.updateDraft(100)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 100,
      maximumLevel: 100
    )
    await waitForPlay(player)

    route.deviceUID = "HEADPHONES"
    await waitForStop(player)
    let countAfterRouteChange = player.plays.count
    try? await Task.sleep(for: .milliseconds(30))

    #expect(player.stopCount == 1)
    #expect(player.plays.count == countAfterRouteChange)
  }

  @Test("A new press invalidates an older release completion")
  @MainActor
  func newPressInvalidatesOlderRelease() async {
    let writeGate = FeedbackAsyncGate()
    let display = FeedbackVolumeController(writeGate: writeGate)
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" }
    )

    store.updateDraft(25)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 25,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )
    await waitForWrite(display)

    store.updateDraft(24)
    store.queueDraftApply()
    coordinator.observePress(
      press(.decrease),
      targetDeviceUID: "LG-UID",
      targetLevel: 24,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.decrease),
      targetDeviceUID: "LG-UID"
    )

    await writeGate.open()
    await waitForPlay(player)

    #expect(player.plays.count == 1)
  }

  @Test("Cancel stops feedback and invalidates a pending release")
  @MainActor
  func cancelStopsAndInvalidates() async {
    let writeGate = FeedbackAsyncGate()
    let display = FeedbackVolumeController(writeGate: writeGate)
    let store = await readyStore(display: display, level: 24)
    let player = StubFeedbackPlayer()
    let coordinator = VolumeFeedbackCoordinator(
      store: store,
      player: player,
      targetDeviceProvider: { "LG-UID" }
    )

    store.updateDraft(25)
    store.queueDraftApply()
    coordinator.observePress(
      press(.increase),
      targetDeviceUID: "LG-UID",
      targetLevel: 25,
      maximumLevel: 100
    )
    coordinator.observeRelease(
      release(.increase),
      targetDeviceUID: "LG-UID"
    )
    await waitForWrite(display)

    coordinator.cancel()
    await writeGate.open()
    await waitForStoreToSettle(store)

    #expect(player.stopCount == 1)
    #expect(player.plays.isEmpty)
  }

  private func press(
    _ action: VolumeMediaKeyAction
  ) -> VolumeMediaKeyEvent {
    VolumeMediaKeyEvent(action: action, state: .pressed)
  }

  private func release(
    _ action: VolumeMediaKeyAction,
    shouldInvertFeedback: Bool = false
  ) -> VolumeMediaKeyEvent {
    VolumeMediaKeyEvent(
      action: action,
      state: .released,
      shouldInvertFeedback: shouldInvertFeedback
    )
  }

  @MainActor
  private func readyStore(
    display: FeedbackVolumeController,
    level: Int
  ) async -> VolumeStore {
    await display.setCurrent(level)
    let store = VolumeStore(controller: display)
    await store.refresh()
    return store
  }

  @MainActor
  private func waitForWrite(_ display: FeedbackVolumeController) async {
    for _ in 0..<1_000 {
      if await !display.writes().isEmpty {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for a preview write.")
  }

  @MainActor
  private func waitForPlay(
    _ player: StubFeedbackPlayer,
    count: Int = 1
  ) async {
    for _ in 0..<1_000 {
      if player.plays.count >= count {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for volume feedback.")
  }

  @MainActor
  private func waitForStop(_ player: StubFeedbackPlayer) async {
    for _ in 0..<1_000 {
      if player.stopCount > 0 {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for volume feedback to stop.")
  }

  @MainActor
  private func waitForStoreToSettle(_ store: VolumeStore) async {
    for _ in 0..<1_000 {
      if !store.isBusy {
        await Task.yield()
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for the volume store.")
  }
}

private actor FeedbackAsyncGate {
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

private actor FeedbackVolumeController: VolumeControlling {
  private let writeGate: FeedbackAsyncGate?
  private let writeError: (any Error)?
  private var current = 0
  private var writtenLevels: [Int] = []

  init(
    writeGate: FeedbackAsyncGate? = nil,
    writeError: (any Error)? = nil
  ) {
    self.writeGate = writeGate
    self.writeError = writeError
  }

  func readVolume() async throws -> VolumeReading {
    reading()
  }

  func writeVolume(to level: Int) async throws {
    writtenLevels.append(level)
    if let writeGate {
      await writeGate.wait()
    }
    if let writeError {
      throw writeError
    }
    current = level
  }

  func setVolume(to level: Int) async throws -> VolumeReading {
    current = level
    return reading()
  }

  func resetConnection() async {}

  func setCurrent(_ level: Int) {
    current = level
  }

  func writes() -> [Int] {
    writtenLevels
  }

  private func reading() -> VolumeReading {
    VolumeReading(
      display: "LG 39GX950B",
      current: current,
      maximum: 100
    )
  }
}

@MainActor
private final class StubFeedbackPlayer: VolumeFeedbackPlaying {
  private(set) var plays: [FeedbackPlay] = []
  private(set) var stopCount = 0

  func play(
    on deviceUID: String?,
    invertingSystemPreference: Bool
  ) {
    plays.append(
      FeedbackPlay(
        deviceUID: deviceUID,
        invertsPreference: invertingSystemPreference
      )
    )
  }

  func stop() {
    stopCount += 1
  }
}

private struct FeedbackPlay: Equatable {
  let deviceUID: String?
  let invertsPreference: Bool
}

@MainActor
private final class StubFeedbackRoute {
  var deviceUID: String?

  init(deviceUID: String?) {
    self.deviceUID = deviceUID
  }
}

@MainActor
private final class StubFeedbackUptime {
  var value: TimeInterval = 0
}

private enum FeedbackTestError: Error {
  case write
}
