import Foundation
import Observation

public enum VolumePreviewAcceptance: Equatable, Sendable {
  case accepted(level: Int)
  case superseded
  case cancelled
  case unavailable(message: String?)
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
  @ObservationIgnored private var draftRevision: UInt = 0
  private var isRefreshing = false
  private var isRefreshRequested = false
  @ObservationIgnored private var refreshRequestTask: Task<Void, Never>?
  @ObservationIgnored private var pendingPreview: PendingWrite?
  @ObservationIgnored private var previewInFlight: PendingWrite?
  @ObservationIgnored private var previewWorker: Task<Void, Never>?
  @ObservationIgnored private var trailingConfirmation: Task<Void, Never>?
  @ObservationIgnored private var confirmationGeneration: UInt = 0
  @ObservationIgnored private var activeConfirmations = 0
  @ObservationIgnored private var lastIssuedLevel: Int?
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

  public var sliderRange: ClosedRange<Double> {
    0...Double(max(maximumLevel, 1))
  }

  public func updateDraft(_ value: Double) {
    draftLevel = min(max(value, sliderRange.lowerBound), sliderRange.upperBound)
    draftRevision &+= 1
    resolveSupersededPreviewAcceptanceWaiters()
  }

  public func requestRefresh() {
    guard refreshRequestTask == nil, !isRefreshing else { return }

    isRefreshRequested = true
    refreshRequestTask = Task { @MainActor [weak self] in
      guard let self else { return }

      while isBusy {
        do {
          try await Task.sleep(for: .milliseconds(10))
        } catch {
          finishRefreshRequest()
          return
        }
      }

      await performRefresh()
      finishRefreshRequest()
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

  public func refresh() async {
    if let refreshRequestTask {
      await refreshRequestTask.value
      return
    }

    await performRefresh()
  }

  private func performRefresh() async {
    guard !isBusy else { return }

    trailingConfirmation?.cancel()
    trailingConfirmation = nil
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
      applyConfirmed(
        try await controller.readVolume(),
        updateDraft: revision == draftRevision && pendingPreview == nil
      )
    } catch {
      markUnavailableAfterFailure(Self.message(for: error))
    }
  }

  public func applyDraft() async {
    guard let request = currentRequest else { return }

    enqueuePreview(request, coalesceInitialWrite: false)
    trailingConfirmation?.cancel()
    trailingConfirmation = nil
    confirmationGeneration &+= 1
    let generation = confirmationGeneration
    await confirm(request, generation: generation)
  }

  private var currentRequest: PendingWrite? {
    guard confirmedLevel != nil else { return nil }

    return PendingWrite(
      level: Int(draftLevel.rounded()),
      revision: draftRevision
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

      guard confirmedLevel != nil else { return }
      if activeConfirmations == 0,
        request.level == lastIssuedLevel
      {
        resolveAcceptedPreviewWaiters(level: request.level)
        continue
      }

      previewInFlight = request
      do {
        try await controller.writeVolume(to: request.level)
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
    trailingConfirmation?.cancel()
    confirmationGeneration &+= 1
    let generation = confirmationGeneration

    trailingConfirmation = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }

      guard let self,
        self.confirmationGeneration == generation
      else {
        return
      }

      self.trailingConfirmation = nil
      await self.confirm(request, generation: generation)
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
  }

  private func recoverAfterWriteFailure(
    _ request: PendingWrite,
    generation: UInt? = nil,
    message: String
  ) async -> RecoveryOutcome {
    do {
      let reading = try await controller.readVolume()
      guard isCurrent(request, generation: generation) else {
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
      guard isCurrent(request, generation: generation) else {
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
    trailingConfirmation?.cancel()
    trailingConfirmation = nil
    confirmationGeneration &+= 1
    lastIssuedLevel = nil
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
  }

  private func finishRefreshRequest() {
    isRefreshRequested = false
    refreshRequestTask = nil
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
}

private struct PreviewAcceptanceWaiter {
  let request: PendingWrite
  let continuation: CheckedContinuation<VolumePreviewAcceptance, Never>
}

private enum RecoveryOutcome {
  case resolved
  case stale
}
