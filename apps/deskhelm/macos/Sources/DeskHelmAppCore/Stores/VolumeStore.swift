import Foundation
import Observation

public enum VolumePreviewAcceptance: Equatable, Sendable {
  case accepted(level: Int)
  case superseded
  case cancelled
  case unavailable(message: String?)
}

public enum VolumeRefreshResult: Equatable, Sendable {
  case confirmed
  case failed
  case skipped
}

@MainActor
@Observable
public final class VolumeStore {
  public private(set) var displayName = "External display"
  public private(set) var confirmedLevel: Int?
  public private(set) var maximumLevel = 100
  public private(set) var isBusy = false
  public private(set) var errorMessage: String?
  public var draftLevel = 0.0
  @ObservationIgnored public var communicationFailureHandler: ((String) -> Void)?

  private let controller: any VolumeControlling
  private let confirmationClock = ContinuousClock()
  @ObservationIgnored private var draftRevision: UInt = 0
  private var isRefreshing = false
  private var isRefreshRequested = false
  @ObservationIgnored private var refreshRequestTask: Task<VolumeRefreshResult, Never>?
  @ObservationIgnored private var resetBarrier: Task<Void, Never>?
  @ObservationIgnored private var pendingPreview: PendingWrite?
  @ObservationIgnored private var previewInFlight: PendingWrite?
  @ObservationIgnored private var previewWorker: Task<Void, Never>?
  @ObservationIgnored private var trailingConfirmation: Task<Void, Never>?
  @ObservationIgnored private var trailingConfirmationDeadline: ContinuousClock.Instant?
  @ObservationIgnored private var trailingConfirmationRequest: PendingWrite?
  @ObservationIgnored private var confirmationGeneration: UInt = 0
  @ObservationIgnored private var activeConfirmations = 0
  @ObservationIgnored private var lastIssuedLevel: Int?
  @ObservationIgnored private var connectionGeneration: UInt = 0
  @ObservationIgnored private var isDisplayConnectionReconfiguring = false
  @ObservationIgnored private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  @ObservationIgnored private var previewAcceptanceWaiters:
    [UUID:
      PreviewAcceptanceWaiter] = [:]

  public init(controller: any VolumeControlling) {
    self.controller = controller
  }

  public var isAdjustable: Bool {
    confirmedLevel != nil
  }

  public var isRefreshInProgress: Bool {
    isRefreshing || isRefreshRequested
  }

  var showsInitialLoadingIndicator: Bool {
    isBusy && confirmedLevel == nil && errorMessage == nil
  }

  var scheduledConfirmationDeadline: ContinuousClock.Instant? {
    trailingConfirmationDeadline
  }

  public var sliderRange: ClosedRange<Double> {
    0...Double(max(maximumLevel, 1))
  }

  @discardableResult
  public func updateDraft(_ value: Double) -> Bool {
    let clamped = min(
      max(value, sliderRange.lowerBound),
      sliderRange.upperBound
    )
    guard clamped != draftLevel else { return false }

    let previousTarget = Int(draftLevel.rounded())
    draftLevel = clamped
    guard Int(clamped.rounded()) != previousTarget else { return true }

    draftRevision &+= 1
    resolveSupersededPreviewAcceptanceWaiters()
    return true
  }

  public func requestRefresh() {
    guard refreshRequestTask == nil, !isRefreshing else { return }

    isRefreshRequested = true
    refreshRequestTask = Task { @MainActor [weak self] in
      guard let self else { return .skipped }

      await waitUntilIdle()
      guard !Task.isCancelled else {
        finishRefreshRequest()
        return .skipped
      }

      let result = await performRefresh()
      finishRefreshRequest()
      return result
    }
  }

  public func queueDraftApply() {
    guard let request = currentRequest else { return }

    enqueuePreview(request, coalesceInitialWrite: true)
    scheduleTrailingConfirmation(for: request)
  }

  public func awaitCurrentDraftPreviewAcceptance()
    async -> VolumePreviewAcceptance
  {
    guard let request = currentRequest else {
      return .unavailable(message: errorMessage)
    }

    if pendingPreview == nil,
      previewInFlight == nil,
      request.level == lastIssuedLevel
    {
      return .accepted(level: request.level)
    }

    enqueuePreview(request, coalesceInitialWrite: false)

    if pendingPreview == nil,
      previewInFlight == nil,
      request.level == lastIssuedLevel
    {
      return .accepted(level: request.level)
    }

    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: .cancelled)
          return
        }

        previewAcceptanceWaiters[waiterID] = PreviewAcceptanceWaiter(
          request: request,
          continuation: continuation
        )
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelPreviewAcceptanceWaiter(waiterID)
      }
    }
  }

  @discardableResult
  public func refresh() async -> VolumeRefreshResult {
    if let refreshRequestTask {
      return await refreshRequestTask.value
    }

    return await performRefresh()
  }

  public func displayConnectionWillReconfigure() {
    connectionGeneration &+= 1
    isDisplayConnectionReconfiguring = true
    resolveAllPreviewAcceptanceWaiters(with: .cancelled)
    previewWorker?.cancel()
    refreshRequestTask?.cancel()
    invalidatePendingOperations()
    draftRevision &+= 1
    confirmedLevel = nil
    errorMessage = nil
    updateBusyState()

    let precedingReset = resetBarrier
    let controller = controller
    resetBarrier = Task { @MainActor [weak self] in
      if let precedingReset {
        await precedingReset.value
      }
      guard let self else { return }

      await waitUntilIdle()
      await controller.resetConnection()
    }
  }

  public func displayConnectionDidSettle() {
    isDisplayConnectionReconfiguring = false
  }

  public func waitUntilIdle() async {
    guard isBusy else { return }

    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled, isBusy else {
          continuation.resume()
          return
        }
        idleWaiters[waiterID] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelIdleWaiter(waiterID)
      }
    }
  }

  private func performRefresh() async -> VolumeRefreshResult {
    let generation = connectionGeneration
    if let resetBarrier {
      await resetBarrier.value
    }
    guard
      !Task.isCancelled,
      generation == connectionGeneration,
      !isDisplayConnectionReconfiguring,
      !isBusy
    else {
      return .skipped
    }

    cancelTrailingConfirmation()
    confirmationGeneration &+= 1
    isRefreshing = true
    updateBusyState()
    errorMessage = nil
    let revision = draftRevision
    defer {
      isRefreshing = false
      startPreviewWorkerIfNeeded(coalesceInitialWrite: false)
      updateBusyState()
    }

    do {
      let reading = try await controller.readVolume()
      guard
        !Task.isCancelled,
        generation == connectionGeneration,
        !isDisplayConnectionReconfiguring
      else {
        return .skipped
      }
      applyConfirmed(
        reading,
        updateDraft: revision == draftRevision && pendingPreview == nil
      )
      return .confirmed
    } catch {
      guard
        !Task.isCancelled,
        generation == connectionGeneration,
        !isDisplayConnectionReconfiguring
      else {
        return .skipped
      }
      markUnavailableAfterFailure(Self.message(for: error))
      return .failed
    }
  }

  public func applyDraft() async {
    guard let request = currentRequest else { return }

    enqueuePreview(request, coalesceInitialWrite: false)
    cancelTrailingConfirmation()
    confirmationGeneration &+= 1
    let generation = confirmationGeneration
    await confirm(request, generation: generation)
  }

  private var currentRequest: PendingWrite? {
    guard
      confirmedLevel != nil,
      !isDisplayConnectionReconfiguring
    else {
      return nil
    }

    return PendingWrite(
      level: Int(draftLevel.rounded()),
      revision: draftRevision,
      connectionGeneration: connectionGeneration
    )
  }

  private func enqueuePreview(
    _ request: PendingWrite,
    coalesceInitialWrite: Bool
  ) {
    if pendingPreview?.level == request.level {
      pendingPreview = request
      return
    }

    if pendingPreview == nil,
      previewInFlight?.level == request.level
    {
      return
    }

    if previewWorker == nil,
      activeConfirmations == 0,
      request.level == lastIssuedLevel
    {
      return
    }

    pendingPreview = request
    startPreviewWorkerIfNeeded(
      coalesceInitialWrite: coalesceInitialWrite
    )
  }

  private func startPreviewWorkerIfNeeded(
    coalesceInitialWrite: Bool
  ) {
    guard !isRefreshing, previewWorker == nil, pendingPreview != nil else {
      return
    }

    errorMessage = nil
    previewWorker = Task { @MainActor [weak self] in
      if coalesceInitialWrite {
        try? await Task.sleep(for: .milliseconds(24))
      }

      await self?.drainPendingPreviews()
    }
    updateBusyState()
  }

  private func drainPendingPreviews() async {
    defer {
      previewInFlight = nil
      previewWorker = nil
      updateBusyState()
    }

    while !Task.isCancelled, let request = pendingPreview {
      pendingPreview = nil

      guard
        confirmedLevel != nil,
        request.connectionGeneration == connectionGeneration
      else {
        return
      }
      if activeConfirmations == 0,
        request.level == lastIssuedLevel
      {
        resolveAcceptedPreviewWaiters(level: request.level)
        continue
      }

      previewInFlight = request
      do {
        try await controller.writeVolume(to: request.level)
        guard
          !Task.isCancelled,
          request.connectionGeneration == connectionGeneration
        else {
          return
        }
        previewInFlight = nil
        lastIssuedLevel = request.level
        resolveAcceptedPreviewWaiters(level: request.level)
      } catch {
        previewInFlight = nil
        lastIssuedLevel = nil
        resolveUnavailablePreviewWaiters(
          level: request.level,
          message: Self.message(for: error)
        )
        let hasNewerIntent =
          pendingPreview != nil || request.revision != draftRevision
        if hasNewerIntent {
          continue
        }

        switch await recoverAfterWriteFailure(
          request,
          message: Self.message(for: error)
        ) {
        case .resolved:
          return
        case .stale:
          continue
        }
      }
    }
  }

  private func scheduleTrailingConfirmation(
    for request: PendingWrite
  ) {
    confirmationGeneration &+= 1
    trailingConfirmationRequest = request
    trailingConfirmationDeadline = confirmationClock.now.advanced(
      by: .milliseconds(150)
    )

    guard trailingConfirmation == nil else { return }

    trailingConfirmation = Task { @MainActor [weak self] in
      await self?.runTrailingConfirmation()
    }
  }

  private func runTrailingConfirmation() async {
    while !Task.isCancelled {
      guard let deadline = trailingConfirmationDeadline else {
        trailingConfirmation = nil
        return
      }

      do {
        try await confirmationClock.sleep(until: deadline)
      } catch {
        return
      }

      guard deadline == trailingConfirmationDeadline else { continue }
      guard let request = trailingConfirmationRequest else {
        trailingConfirmation = nil
        return
      }

      let generation = confirmationGeneration
      trailingConfirmationDeadline = nil
      trailingConfirmationRequest = nil
      trailingConfirmation = nil
      await confirm(request, generation: generation)
      return
    }
  }

  private func confirm(
    _ request: PendingWrite,
    generation: UInt
  ) async {
    while isRefreshing {
      try? await Task.sleep(for: .milliseconds(1))
    }

    guard isCurrent(request, generation: generation) else { return }
    guard await ensurePreviewSent(request, generation: generation) else {
      return
    }

    activeConfirmations += 1
    updateBusyState()
    defer {
      activeConfirmations -= 1
      updateBusyState()
    }
    errorMessage = nil
    do {
      let reading = try await controller.readVolume()
      guard isCurrent(request, generation: generation) else { return }

      if reading.current == request.level {
        applyConfirmed(reading)
        return
      }

      let rewritten = try await controller.setVolume(to: request.level)
      guard isCurrent(request, generation: generation) else { return }

      applyConfirmed(rewritten)
    } catch {
      guard isCurrent(request, generation: generation) else { return }

      _ = await recoverAfterWriteFailure(
        request,
        generation: generation,
        message: Self.message(for: error)
      )
    }
  }

  private func ensurePreviewSent(
    _ request: PendingWrite,
    generation: UInt
  ) async -> Bool {
    guard isCurrent(request, generation: generation) else { return false }

    enqueuePreview(request, coalesceInitialWrite: false)
    if let previewWorker {
      await previewWorker.value
    }

    return isCurrent(request, generation: generation)
      && lastIssuedLevel == request.level
  }

  private func isCurrent(
    _ request: PendingWrite,
    generation: UInt
  ) -> Bool {
    generation == confirmationGeneration
      && request.revision == draftRevision
      && request.connectionGeneration == connectionGeneration
  }

  private func recoverAfterWriteFailure(
    _ request: PendingWrite,
    generation: UInt? = nil,
    message: String
  ) async -> RecoveryOutcome {
    guard
      !Task.isCancelled,
      isCurrent(request, generation: generation)
    else {
      return .stale
    }

    do {
      let reading = try await controller.readVolume()
      guard
        !Task.isCancelled,
        isCurrent(request, generation: generation)
      else {
        return .stale
      }

      invalidatePendingOperations()
      draftRevision &+= 1
      applyConfirmed(reading)
      if reading.current != request.level {
        publishFailure(message)
      }
      return .resolved
    } catch {
      guard
        !Task.isCancelled,
        isCurrent(request, generation: generation)
      else {
        return .stale
      }

      markUnavailableAfterFailure(message)
      return .resolved
    }
  }

  private func isCurrent(
    _ request: PendingWrite,
    generation: UInt?
  ) -> Bool {
    request.revision == draftRevision
      && request.connectionGeneration == connectionGeneration
      && (generation == nil || generation == confirmationGeneration)
  }

  private func markUnavailableAfterFailure(_ message: String) {
    resolveAllPreviewAcceptanceWaiters(
      with: .unavailable(message: message)
    )
    invalidatePendingOperations()
    draftRevision &+= 1
    confirmedLevel = nil
    publishFailure(message)
  }

  private func invalidatePendingOperations() {
    pendingPreview = nil
    cancelTrailingConfirmation()
    confirmationGeneration &+= 1
    lastIssuedLevel = nil
  }

  private func cancelTrailingConfirmation() {
    trailingConfirmation?.cancel()
    trailingConfirmation = nil
    trailingConfirmationDeadline = nil
    trailingConfirmationRequest = nil
  }

  private func applyConfirmed(
    _ reading: VolumeReading,
    updateDraft: Bool = true
  ) {
    displayName = reading.display
    confirmedLevel = reading.current
    maximumLevel = reading.maximum
    lastIssuedLevel = reading.current
    if updateDraft {
      draftLevel = Double(reading.current)
    }
    errorMessage = nil
  }

  private func updateBusyState() {
    isBusy =
      isRefreshing || previewWorker != nil || activeConfirmations > 0
    guard !isBusy, !idleWaiters.isEmpty else { return }

    let waiters = Array(idleWaiters.values)
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func finishRefreshRequest() {
    isRefreshRequested = false
    refreshRequestTask = nil
  }

  private func cancelIdleWaiter(_ id: UUID) {
    guard let waiter = idleWaiters.removeValue(forKey: id) else { return }
    waiter.resume()
  }

  private func publishFailure(_ message: String) {
    errorMessage = message
    communicationFailureHandler?(message)
  }

  private func resolveAcceptedPreviewWaiters(level: Int) {
    let currentRevision = draftRevision
    resolvePreviewAcceptanceWaiters { waiter in
      guard waiter.request.level == level else { return nil }

      return waiter.request.revision == currentRevision
        ? .accepted(level: level)
        : .superseded
    }
  }

  private func resolveUnavailablePreviewWaiters(
    level: Int,
    message: String
  ) {
    resolvePreviewAcceptanceWaiters { waiter in
      guard waiter.request.level == level else { return nil }
      return .unavailable(message: message)
    }
  }

  private func resolveSupersededPreviewAcceptanceWaiters() {
    let currentRevision = draftRevision
    resolvePreviewAcceptanceWaiters { waiter in
      waiter.request.revision == currentRevision ? nil : .superseded
    }
  }

  private func resolveAllPreviewAcceptanceWaiters(
    with result: VolumePreviewAcceptance
  ) {
    resolvePreviewAcceptanceWaiters { _ in result }
  }

  private func cancelPreviewAcceptanceWaiter(_ id: UUID) {
    guard let waiter = previewAcceptanceWaiters.removeValue(forKey: id) else {
      return
    }
    waiter.continuation.resume(returning: .cancelled)
  }

  private func resolvePreviewAcceptanceWaiters(
    _ result: (PreviewAcceptanceWaiter) -> VolumePreviewAcceptance?
  ) {
    var resolutions: [(UUID, VolumePreviewAcceptance)] = []
    for (id, waiter) in previewAcceptanceWaiters {
      guard let resolution = result(waiter) else { continue }
      resolutions.append((id, resolution))
    }

    for (id, resolution) in resolutions {
      guard let waiter = previewAcceptanceWaiters.removeValue(forKey: id) else {
        continue
      }
      waiter.continuation.resume(returning: resolution)
    }
  }

  private static func message(for error: Error) -> String {
    if let localizedError = error as? any LocalizedError,
      let description = localizedError.errorDescription
    {
      return description
    }

    return error.localizedDescription
  }
}

private struct PendingWrite {
  let level: Int
  let revision: UInt
  let connectionGeneration: UInt
}

private struct PreviewAcceptanceWaiter {
  let request: PendingWrite
  let continuation: CheckedContinuation<VolumePreviewAcceptance, Never>
}

private enum RecoveryOutcome {
  case resolved
  case stale
}
