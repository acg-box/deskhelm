import Foundation
import Testing

@testable import DeskHelmAppCore

@Suite("Volume store")
struct VolumeStoreTests {
  @Test("Only an unresolved initial read shows the loading indicator")
  @MainActor
  func initialLoadingIndicator() async {
    let readGate = TestGate()
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      readGates: [0: readGate]
    )
    let store = VolumeStore(controller: controller)

    let refresh = Task { @MainActor in
      await store.refresh()
    }
    await waitForReadCount(1, controller: controller)

    #expect(store.isBusy)
    #expect(store.isRefreshInProgress)
    #expect(store.showsInitialLoadingIndicator)

    await readGate.open()
    await refresh.value

    #expect(!store.isBusy)
    #expect(!store.isRefreshInProgress)
    #expect(!store.showsInitialLoadingIndicator)
  }

  @Test("Draft volume remains smooth and clamps to the supported range")
  @MainActor
  func smoothDraft() {
    let store = VolumeStore(controller: StubVolumeController())

    store.updateDraft(24.4)
    #expect(abs(store.draftLevel - 24.4) < 0.001)

    store.updateDraft(-1)
    #expect(store.draftLevel == 0)

    store.updateDraft(101)
    #expect(store.draftLevel == 100)
  }

  @Test("Core rejects an unsupported display volume range")
  func unsupportedMaximum() {
    do {
      _ = try DeskHelmCore.validatedReading(
        display: "LG ULTRAGEAR+",
        current: 25,
        maximum: 50
      )
      Issue.record("Expected an unsupported volume range error.")
    } catch let error as VolumeControlError {
      #expect(
        error
          == .invalidResponse(
            "The display reports a maximum volume of 50. "
              + "DeskHelm supports displays with a 0–100 volume range."
          )
      )
    } catch {
      Issue.record("Received an unexpected error: \(error)")
    }
  }

  @Test("Refresh publishes a confirmed hardware reading")
  @MainActor
  func refreshSuccess() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))]
    )
    let store = VolumeStore(controller: controller)

    await store.refresh()

    #expect(store.displayName == "LG ULTRAGEAR+")
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 24)
    #expect(store.maximumLevel == 100)
    #expect(store.errorMessage == nil)
  }

  @Test("Refresh exposes communication failures")
  @MainActor
  func refreshFailure() async {
    let controller = StubVolumeController(
      readResponses: [.failure(.unavailable)]
    )
    let store = VolumeStore(controller: controller)
    var reportedFailures: [String] = []
    store.communicationFailureHandler = { reportedFailures.append($0) }

    await store.refresh()

    #expect(store.confirmedLevel == nil)
    #expect(store.errorMessage == "DDC/CI unavailable")
    #expect(reportedFailures == ["DDC/CI unavailable"])
    #expect(!store.isBusy)
  }

  @Test("Release sends an unsent preview before its final readback")
  @MainActor
  func releaseWithoutPriorPreview() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
      ],
      writeResponses: [.success(())]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(24.6)

    await store.applyDraft()

    #expect(await controller.previewedLevels() == [25])
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(
      await controller.operations()
        == [.read, .write(25), .read]
    )
    #expect(store.confirmedLevel == 25)
    #expect(store.draftLevel == 25)
    #expect(store.errorMessage == nil)
  }

  @Test("Preview acceptance awaits the latest coalesced pending target")
  @MainActor
  func previewAcceptanceAwaitsPendingTarget() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      writeResponses: [.success(())]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    store.updateDraft(35)
    store.queueDraftApply()

    let result = await store.awaitCurrentDraftPreviewAcceptance()

    #expect(result == .accepted(level: 35))
    #expect(await controller.previewedLevels() == [35])
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 35)
  }

  @Test("Preview acceptance joins the latest in-flight target")
  @MainActor
  func previewAcceptanceJoinsInFlightTarget() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      writeResponses: [.success(())],
      writeDelay: .milliseconds(40)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)

    let result = await store.awaitCurrentDraftPreviewAcceptance()

    #expect(result == .accepted(level: 25))
    #expect(await controller.previewedLevels() == [25])
    #expect(store.confirmedLevel == 24)
  }

  @Test("Preview acceptance awaits the latest target behind an in-flight write")
  @MainActor
  func previewAcceptanceAwaitsTargetBehindInFlightWrite() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      writeResponses: [.success(()), .success(())],
      writeDelay: .milliseconds(40)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    store.updateDraft(35)
    store.queueDraftApply()

    let result = await store.awaitCurrentDraftPreviewAcceptance()

    #expect(result == .accepted(level: 35))
    #expect(await controller.previewedLevels() == [25, 35])
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 35)
  }

  @Test("A superseded preview acceptance reports stale intent")
  @MainActor
  func supersededPreviewAcceptance() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      writeResponses: [.success(())],
      writeDelay: .milliseconds(40)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    let staleAcceptance = Task { @MainActor in
      await store.awaitCurrentDraftPreviewAcceptance()
    }
    await Task.yield()

    store.updateDraft(35)

    #expect(await staleAcceptance.value == .superseded)
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 35)
  }

  @Test("Preview acceptance is unavailable without confirmed display state")
  @MainActor
  func previewAcceptanceRequiresConfirmedState() async {
    let controller = StubVolumeController()
    let store = VolumeStore(controller: controller)
    store.updateDraft(25)

    let result = await store.awaitCurrentDraftPreviewAcceptance()

    #expect(result == .unavailable(message: nil))
    #expect(await controller.operations().isEmpty)
  }

  @Test("Canceling preview acceptance removes its pending waiter")
  @MainActor
  func cancelPreviewAcceptance() async {
    let controller = StubVolumeController(
      readResponses: [.success(Self.reading(level: 24))],
      writeResponses: [.success(())],
      writeDelay: .milliseconds(40)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(25)

    let acceptance = Task { @MainActor in
      await store.awaitCurrentDraftPreviewAcceptance()
    }
    await waitForPreviewCount(1, controller: controller)
    acceptance.cancel()

    #expect(await acceptance.value == .cancelled)
    await waitUntilIdle(store)
    #expect(await controller.previewedLevels() == [25])
  }

  @Test("Preview acceptance exposes a transport failure")
  @MainActor
  func previewAcceptanceFailure() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
      ],
      writeResponses: [.failure(.unavailable)]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(25)

    let result = await store.awaitCurrentDraftPreviewAcceptance()
    await waitForError(store)

    #expect(
      result == .unavailable(message: "DDC/CI unavailable")
    )
    #expect(store.confirmedLevel == 24)
    #expect(store.errorMessage == "DDC/CI unavailable")
  }

  @Test("Accepted current preview does not duplicate an active confirmation")
  @MainActor
  func acceptedPreviewDuringConfirmation() async {
    let confirmationReadGate = TestGate()
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
      ],
      writeResponses: [.success(())],
      readGates: [1: confirmationReadGate]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    await waitForReadCount(2, controller: controller)

    let result = await store.awaitCurrentDraftPreviewAcceptance()

    #expect(result == .accepted(level: 25))
    #expect(await controller.previewedLevels() == [25])
    #expect(store.confirmedLevel == 24)

    await confirmationReadGate.open()
    await waitForConfirmedLevel(25, store: store)
  }

  @Test("Idle confirmation accepts a matching read without an exact rewrite")
  @MainActor
  func matchingReadAvoidsRewrite() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 35)),
      ],
      writeResponses: [.success(()), .success(())],
      writeDelay: .milliseconds(40)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)

    store.updateDraft(30)
    store.queueDraftApply()
    store.updateDraft(35)
    store.queueDraftApply()

    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 35)
    #expect(store.isBusy)
    #expect(!store.isRefreshInProgress)
    #expect(!store.showsInitialLoadingIndicator)

    await waitForPreviewCount(2, controller: controller)
    #expect(await controller.previewedLevels() == [25, 35])
    #expect(store.confirmedLevel == 24)

    await waitForConfirmedLevel(35, store: store)
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 35)
    #expect(store.draftLevel == 35)
    #expect(!store.isBusy)
  }

  @Test("A mismatching confirmation read triggers one exact rewrite")
  @MainActor
  func mismatchFallsBackToExactRewrite() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
      ],
      writeResponses: [.success(())],
      setResponses: [.success(Self.reading(level: 25))]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(25)

    await store.applyDraft()

    #expect(await controller.previewedLevels() == [25])
    #expect(await controller.confirmedLevels() == [25])
    #expect(
      await controller.operations()
        == [.read, .write(25), .read, .set(25)]
    )
    #expect(store.confirmedLevel == 25)
    #expect(store.draftLevel == 25)
    #expect(store.errorMessage == nil)
  }

  @Test("Refresh cancels a pending trailing confirmation")
  @MainActor
  func refreshCancelsTrailingConfirmation() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 30)),
      ],
      writeResponses: [.success(())]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    await waitUntilIdle(store)
    await store.refresh()
    try? await Task.sleep(for: .milliseconds(180))

    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 30)
    #expect(store.draftLevel == 30)
    #expect(store.errorMessage == nil)
  }

  @Test("A requested refresh waits for an active preview")
  @MainActor
  func requestedRefreshWaitsForPreview() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
      ],
      writeResponses: [.success(())],
      writeDelay: .milliseconds(50)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    #expect(store.isBusy)

    store.requestRefresh()
    #expect(store.isRefreshInProgress)
    #expect(await controller.readCount() == 1)

    await waitForReadCount(2, controller: controller)
    await waitUntilRefreshCompletes(store)

    #expect(
      await controller.operations()
        == [.read, .write(25), .read]
    )
    #expect(store.confirmedLevel == 25)
    #expect(store.draftLevel == 25)
    #expect(!store.isRefreshInProgress)
    #expect(store.errorMessage == nil)
  }

  @Test("A direct refresh joins an already requested refresh")
  @MainActor
  func directRefreshJoinsRequestedRefresh() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
      ],
      writeResponses: [.success(())],
      writeDelay: .milliseconds(50)
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)

    store.requestRefresh()
    await store.refresh()
    await waitUntilRefreshCompletes(store)

    #expect(
      await controller.operations()
        == [.read, .write(25), .read]
    )
    #expect(store.confirmedLevel == 25)
    #expect(store.errorMessage == nil)
  }

  @Test("Returning to confirmed volume still writes the preview back")
  @MainActor
  func returnToConfirmed() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
      ],
      writeResponses: [.success(()), .success(())]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)

    store.updateDraft(24)
    store.queueDraftApply()
    await waitForPreviewCount(2, controller: controller)
    await store.applyDraft()

    #expect(await controller.previewedLevels() == [25, 24])
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 24)
  }

  @Test("A newer intent wins while an older confirmation read is in flight")
  @MainActor
  func newerIntentWinsDuringConfirmation() async {
    let olderReadGate = TestGate()
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
        .success(Self.reading(level: 35)),
      ],
      writeResponses: [.success(()), .success(())],
      readGates: [1: olderReadGate]
    )
    let store = VolumeStore(controller: controller)
    await store.refresh()
    store.updateDraft(25)

    let staleApply = Task { @MainActor in
      await store.applyDraft()
    }
    await waitForReadCount(2, controller: controller)

    store.updateDraft(35)
    await store.applyDraft()
    await olderReadGate.open()
    await staleApply.value

    #expect(await controller.previewedLevels() == [25, 35])
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 35)
    #expect(store.draftLevel == 35)
    #expect(store.errorMessage == nil)
  }

  @Test("A current preview failure rolls back and cancels confirmation")
  @MainActor
  func previewFailure() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
      ],
      writeResponses: [.failure(.unavailable)]
    )
    let store = VolumeStore(controller: controller)
    var reportedFailures: [String] = []
    store.communicationFailureHandler = { reportedFailures.append($0) }
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForError(store)
    try? await Task.sleep(for: .milliseconds(180))

    #expect(await controller.previewedLevels() == [25])
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 24)
    #expect(store.draftLevel == 24)
    #expect(store.errorMessage == "DDC/CI unavailable")
    #expect(reportedFailures == ["DDC/CI unavailable"])
    #expect(!store.isBusy)
  }

  @Test("A failed final confirmation recovers the previewed hardware value")
  @MainActor
  func confirmationRecovery() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 25)),
      ],
      writeResponses: [.success(())],
      setResponses: [.failure(.unavailable)]
    )
    let store = VolumeStore(controller: controller)
    var reportedFailures: [String] = []
    store.communicationFailureHandler = { reportedFailures.append($0) }
    await store.refresh()

    store.updateDraft(25)
    store.queueDraftApply()
    await waitForPreviewCount(1, controller: controller)
    await store.applyDraft()

    #expect(await controller.previewedLevels() == [25])
    #expect(await controller.confirmedLevels() == [25])
    #expect(store.confirmedLevel == 25)
    #expect(store.draftLevel == 25)
    #expect(store.errorMessage == nil)
    #expect(reportedFailures.isEmpty)
    #expect(!store.isBusy)
  }

  @Test("An unrecoverable final-confirmation failure disables adjustment")
  @MainActor
  func confirmationFailure() async {
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .success(Self.reading(level: 24)),
        .failure(.unavailable),
      ],
      writeResponses: [.success(())],
      setResponses: [.failure(.unavailable)]
    )
    let store = VolumeStore(controller: controller)
    var reportedFailures: [String] = []
    store.communicationFailureHandler = { reportedFailures.append($0) }
    await store.refresh()
    store.updateDraft(25)

    await store.applyDraft()

    #expect(await controller.previewedLevels() == [25])
    #expect(await controller.confirmedLevels() == [25])
    #expect(store.confirmedLevel == nil)
    #expect(!store.isAdjustable)
    #expect(store.errorMessage == "DDC/CI unavailable")
    #expect(reportedFailures == ["DDC/CI unavailable"])
    #expect(!store.isBusy)
  }

  @Test("A stale failed confirmation cannot roll back newer intent")
  @MainActor
  func staleConfirmationCannotClobber() async {
    let staleReadGate = TestGate()
    let controller = StubVolumeController(
      readResponses: [
        .success(Self.reading(level: 24)),
        .failure(.unavailable),
        .success(Self.reading(level: 35)),
      ],
      writeResponses: [.success(()), .success(())],
      readGates: [1: staleReadGate]
    )
    let store = VolumeStore(controller: controller)
    var reportedFailures: [String] = []
    store.communicationFailureHandler = { reportedFailures.append($0) }
    await store.refresh()
    store.updateDraft(25)

    let staleApply = Task { @MainActor in
      await store.applyDraft()
    }
    await waitForReadCount(2, controller: controller)

    store.updateDraft(35)
    await store.applyDraft()
    await staleReadGate.open()
    await staleApply.value

    #expect(await controller.previewedLevels() == [25, 35])
    #expect(await controller.confirmedLevels().isEmpty)
    #expect(store.confirmedLevel == 35)
    #expect(store.draftLevel == 35)
    #expect(store.errorMessage == nil)
    #expect(reportedFailures.isEmpty)
    #expect(!store.isBusy)
  }

  private static func reading(level: Int) -> VolumeReading {
    VolumeReading(display: "LG ULTRAGEAR+", current: level, maximum: 100)
  }

  @MainActor
  private func waitForPreviewCount(
    _ count: Int,
    controller: StubVolumeController
  ) async {
    for _ in 0..<500 {
      if await controller.previewedLevels().count >= count {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for \(count) preview writes.")
  }

  @MainActor
  private func waitForReadCount(
    _ count: Int,
    controller: StubVolumeController
  ) async {
    for _ in 0..<500 {
      if await controller.readCount() >= count {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for \(count) volume reads.")
  }

  @MainActor
  private func waitForConfirmedLevel(
    _ level: Int,
    store: VolumeStore
  ) async {
    for _ in 0..<500 {
      if store.confirmedLevel == level, !store.isBusy {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for confirmed volume \(level).")
  }

  @MainActor
  private func waitForError(_ store: VolumeStore) async {
    for _ in 0..<500 {
      if store.errorMessage != nil, !store.isBusy {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for a volume error.")
  }

  @MainActor
  private func waitUntilIdle(_ store: VolumeStore) async {
    for _ in 0..<500 {
      if !store.isBusy {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for the volume store to become idle.")
  }

  @MainActor
  private func waitUntilRefreshCompletes(_ store: VolumeStore) async {
    for _ in 0..<500 {
      if !store.isRefreshInProgress, !store.isBusy {
        return
      }

      try? await Task.sleep(for: .milliseconds(1))
    }

    Issue.record("Timed out waiting for the requested refresh to complete.")
  }
}

private enum StubFailure: LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    "DDC/CI unavailable"
  }
}

private enum StubOperation: Equatable, Sendable {
  case read
  case write(Int)
  case set(Int)
}

private actor TestGate {
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
    let pendingWaiters = waiters
    waiters.removeAll()
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}

private actor StubVolumeController: VolumeControlling {
  private var readResponses: [Result<VolumeReading, StubFailure>]
  private var writeResponses: [Result<Void, StubFailure>]
  private var setResponses: [Result<VolumeReading, StubFailure>]
  private var writeLevels: [Int] = []
  private var setLevels: [Int] = []
  private var readCalls = 0
  private var operationLog: [StubOperation] = []
  private let writeDelay: Duration?
  private let readGates: [Int: TestGate]

  init(
    readResponses: [Result<VolumeReading, StubFailure>] = [],
    writeResponses: [Result<Void, StubFailure>] = [],
    setResponses: [Result<VolumeReading, StubFailure>] = [],
    writeDelay: Duration? = nil,
    readGates: [Int: TestGate] = [:]
  ) {
    self.readResponses = readResponses
    self.writeResponses = writeResponses
    self.setResponses = setResponses
    self.writeDelay = writeDelay
    self.readGates = readGates
  }

  func readVolume() async throws -> VolumeReading {
    operationLog.append(.read)
    let callIndex = readCalls
    readCalls += 1
    guard !readResponses.isEmpty else {
      throw StubFailure.unavailable
    }
    let response = readResponses.removeFirst()
    if let gate = readGates[callIndex] {
      await gate.wait()
    }

    return try response.get()
  }

  func writeVolume(to level: Int) async throws {
    operationLog.append(.write(level))
    writeLevels.append(level)
    if let writeDelay {
      try await Task.sleep(for: writeDelay)
    }
    guard !writeResponses.isEmpty else {
      throw StubFailure.unavailable
    }

    try writeResponses.removeFirst().get()
  }

  func setVolume(to level: Int) async throws -> VolumeReading {
    operationLog.append(.set(level))
    setLevels.append(level)
    return try next(from: &setResponses)
  }

  func previewedLevels() -> [Int] {
    writeLevels
  }

  func confirmedLevels() -> [Int] {
    setLevels
  }

  func readCount() -> Int {
    readCalls
  }

  func operations() -> [StubOperation] {
    operationLog
  }

  private func next(
    from responses: inout [Result<VolumeReading, StubFailure>]
  ) throws -> VolumeReading {
    guard !responses.isEmpty else {
      throw StubFailure.unavailable
    }

    return try responses.removeFirst().get()
  }
}
