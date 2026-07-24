import Foundation
import SwiftUI

package enum VolumeLevelAnimationPlan: Equatable, Sendable {
  case immediate
  case linear(duration: TimeInterval, isContinuous: Bool)

  @MainActor
  package func perform(_ updates: () -> Void) {
    var transaction = Transaction()
    switch self {
    case .immediate:
      transaction.disablesAnimations = true
    case .linear(let duration, let isContinuous):
      transaction.animation = .linear(duration: duration)
      transaction.isContinuous = isContinuous
    }

    withTransaction(transaction, updates)
  }
}

package enum VolumeLevelAnimationPolicy {
  package static func plan(
    previousUpdateUptime: TimeInterval?,
    currentUpdateUptime: TimeInterval,
    isVisible: Bool,
    reduceMotion: Bool,
    animatesFirstUpdate: Bool = false
  ) -> VolumeLevelAnimationPlan {
    guard
      isVisible,
      !reduceMotion
    else {
      return .immediate
    }

    guard let previousUpdateUptime else {
      return animatesFirstUpdate
        ? .linear(duration: isolatedUpdateDuration, isContinuous: false)
        : .immediate
    }

    let interval = currentUpdateUptime - previousUpdateUptime
    guard interval > minimumAnimatedInterval else {
      return .immediate
    }

    if interval <= continuousInputThreshold {
      return .linear(
        duration: min(maximumContinuousDuration, interval * 0.6),
        isContinuous: true
      )
    }

    return .linear(
      duration: isolatedUpdateDuration,
      isContinuous: false
    )
  }

  private static let minimumAnimatedInterval: TimeInterval = 0.018
  private static let continuousInputThreshold: TimeInterval = 0.12
  private static let maximumContinuousDuration: TimeInterval = 0.05
  private static let isolatedUpdateDuration: TimeInterval = 0.08
}
