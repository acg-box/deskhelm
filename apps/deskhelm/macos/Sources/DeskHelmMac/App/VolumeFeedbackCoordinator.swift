import DeskHelmAppCore
import Foundation

@MainActor
protocol VolumeFeedbackCoordinating: AnyObject {
  func observePress(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String,
    targetLevel: Int,
    maximumLevel: Int
  )
  func observeRelease(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  )
  func cancel()
}

@MainActor
final class VolumeFeedbackCoordinator: VolumeFeedbackCoordinating {
  typealias TargetDeviceProvider = @MainActor () -> String?
  typealias UptimeProvider = @MainActor () -> TimeInterval

  private let store: VolumeStore
  private let player: any VolumeFeedbackPlaying
  private let targetDeviceProvider: TargetDeviceProvider
  private let uptimeProvider: UptimeProvider
  private let boundaryInterval: Duration
  private let boundaryWatchdog: TimeInterval
  private var completionTask: Task<Void, Never>?
  private var boundaryTask: Task<Void, Never>?
  private var generation: UInt = 0
  private var activeSequence: FeedbackSequence?

  init(
    store: VolumeStore,
    player: any VolumeFeedbackPlaying = VolumeFeedbackPlayer(),
    targetDeviceProvider: @escaping TargetDeviceProvider = {
      DefaultAudioOutputRoute.currentTargetDeviceUID
    },
    uptimeProvider: @escaping UptimeProvider = {
      ProcessInfo.processInfo.systemUptime
    },
    boundaryInterval: Duration = .seconds(1),
    boundaryWatchdog: TimeInterval = 4
  ) {
    self.store = store
    self.player = player
    self.targetDeviceProvider = targetDeviceProvider
    self.uptimeProvider = uptimeProvider
    self.boundaryInterval = boundaryInterval
    self.boundaryWatchdog = boundaryWatchdog
  }

  func observePress(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String,
    targetLevel: Int,
    maximumLevel: Int
  ) {
    beginOrContinueSequence(
      for: event,
      targetDeviceUID: targetDeviceUID
    )
    activeSequence?.lastEventUptime = uptimeProvider()
    activeSequence?.targetLevel = targetLevel
    activeSequence?.shouldInvertFeedback = event.shouldInvertFeedback

    if event.action == .increase, targetLevel == maximumLevel {
      startBoundaryFeedbackIfNeeded(maximumLevel: maximumLevel)
    }
  }

  func observeRelease(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  ) {
    guard var sequence = activeSequence else { return }
    guard
      sequence.action == event.action,
      sequence.targetDeviceUID == targetDeviceUID
    else {
      cancel()
      return
    }

    sequence.shouldInvertFeedback = event.shouldInvertFeedback
    sequence.lastEventUptime = uptimeProvider()
    activeSequence = nil
    boundaryTask?.cancel()
    boundaryTask = nil

    guard !sequence.boundaryFeedbackStarted else { return }

    completionTask?.cancel()
    completionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == sequence.id {
          completionTask = nil
        }
      }

      let acceptance = await store.awaitCurrentDraftPreviewAcceptance()
      guard
        !Task.isCancelled,
        generation == sequence.id,
        case .accepted(let level) = acceptance,
        level == sequence.targetLevel,
        targetDeviceProvider() == sequence.targetDeviceUID
      else {
        return
      }

      player.play(
        on: sequence.targetDeviceUID,
        invertingSystemPreference: sequence.shouldInvertFeedback
      )
    }
  }

  func cancel() {
    generation &+= 1
    activeSequence = nil
    completionTask?.cancel()
    completionTask = nil
    boundaryTask?.cancel()
    boundaryTask = nil
    player.stop()
  }

  private func beginOrContinueSequence(
    for event: VolumeMediaKeyEvent,
    targetDeviceUID: String
  ) {
    if var sequence = activeSequence,
      sequence.action == event.action,
      sequence.targetDeviceUID == targetDeviceUID
    {
      sequence.shouldInvertFeedback = event.shouldInvertFeedback
      sequence.lastEventUptime = uptimeProvider()
      activeSequence = sequence
      return
    }

    let wasPlayingBoundaryFeedback =
      activeSequence?.boundaryFeedbackStarted == true
    generation &+= 1
    completionTask?.cancel()
    completionTask = nil
    boundaryTask?.cancel()
    boundaryTask = nil
    if wasPlayingBoundaryFeedback {
      player.stop()
    }
    activeSequence = FeedbackSequence(
      id: generation,
      action: event.action,
      targetDeviceUID: targetDeviceUID,
      shouldInvertFeedback: event.shouldInvertFeedback,
      targetLevel: Int(store.draftLevel.rounded()),
      lastEventUptime: uptimeProvider()
    )
  }

  private func startBoundaryFeedbackIfNeeded(maximumLevel: Int) {
    guard
      boundaryTask == nil,
      let sequence = activeSequence
    else {
      return
    }

    boundaryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if activeSequence?.id == sequence.id {
          boundaryTask = nil
        }
      }

      acceptanceLoop: while !Task.isCancelled {
        let acceptance = await store.awaitCurrentDraftPreviewAcceptance()
        guard
          !Task.isCancelled,
          let current = activeSequence,
          current.id == sequence.id
        else {
          return
        }

        switch acceptance {
        case .accepted(let level):
          guard level == maximumLevel else { return }
          break acceptanceLoop
        case .superseded:
          continue
        case .cancelled:
          return
        case .unavailable:
          return
        }
      }

      guard
        var current = activeSequence,
        current.id == sequence.id,
        targetDeviceProvider() == current.targetDeviceUID
      else {
        return
      }

      current.boundaryFeedbackStarted = true
      activeSequence = current
      player.play(
        on: current.targetDeviceUID,
        invertingSystemPreference: current.shouldInvertFeedback
      )

      while !Task.isCancelled {
        do {
          try await Task.sleep(for: boundaryInterval)
        } catch {
          return
        }

        guard
          let latest = activeSequence,
          latest.id == sequence.id
        else {
          return
        }
        guard
          uptimeProvider() - latest.lastEventUptime <= boundaryWatchdog
        else {
          return
        }
        guard targetDeviceProvider() == latest.targetDeviceUID else {
          cancel()
          return
        }

        player.play(
          on: latest.targetDeviceUID,
          invertingSystemPreference: latest.shouldInvertFeedback
        )
      }
    }
  }
}

private struct FeedbackSequence {
  let id: UInt
  let action: VolumeMediaKeyAction
  let targetDeviceUID: String
  var shouldInvertFeedback: Bool
  var targetLevel: Int
  var lastEventUptime: TimeInterval
  var boundaryFeedbackStarted = false
}
