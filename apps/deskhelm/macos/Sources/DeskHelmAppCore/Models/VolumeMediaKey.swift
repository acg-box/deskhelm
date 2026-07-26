import Foundation

public enum VolumeMediaKeyAction: Equatable, Sendable {
  case increase
  case decrease
}

public enum VolumeMediaKeyState: Equatable, Sendable {
  case pressed
  case released
}

public struct VolumeMediaKeyEvent: Equatable, Sendable {
  public let action: VolumeMediaKeyAction
  public let state: VolumeMediaKeyState
  public let shouldInvertFeedback: Bool

  public init(
    action: VolumeMediaKeyAction,
    state: VolumeMediaKeyState,
    shouldInvertFeedback: Bool = false
  ) {
    self.action = action
    self.state = state
    self.shouldInvertFeedback = shouldInvertFeedback
  }
}

public enum VolumeMediaKeyDisposition: Equatable, Sendable {
  case passThrough
  case passThroughAndDispatch(VolumeMediaKeyEvent)
  case consumeAndDispatch(VolumeMediaKeyEvent)
}

public enum VolumeMediaKeyRoutingPolicy {
  public static func disposition(
    for event: VolumeMediaKeyEvent,
    outputMatchesTarget: Bool
  ) -> VolumeMediaKeyDisposition {
    guard outputMatchesTarget else {
      return .passThroughAndDispatch(event)
    }

    return .consumeAndDispatch(event)
  }
}

public enum VolumeMediaKeyDecoder {
  public static func decode(
    subtype: Int16,
    data1: Int,
    shouldInvertFeedback: Bool = false
  ) -> VolumeMediaKeyEvent? {
    guard subtype == auxiliaryControlSubtype else { return nil }

    let payload = UInt32(truncatingIfNeeded: data1)
    let keyCode = Int((payload >> 16) & 0xFFFF)
    let keyState = Int((payload >> 8) & 0xFF)

    let action: VolumeMediaKeyAction
    switch keyCode {
    case volumeUpKeyCode:
      action = .increase
    case volumeDownKeyCode:
      action = .decrease
    default:
      return nil
    }

    switch keyState {
    case keyDownState:
      return VolumeMediaKeyEvent(
        action: action,
        state: .pressed,
        shouldInvertFeedback: shouldInvertFeedback
      )
    case keyUpState:
      return VolumeMediaKeyEvent(
        action: action,
        state: .released,
        shouldInvertFeedback: shouldInvertFeedback
      )
    default:
      return nil
    }
  }

  private static let auxiliaryControlSubtype: Int16 = 8
  private static let volumeUpKeyCode = 0
  private static let volumeDownKeyCode = 1
  private static let keyDownState = 10
  private static let keyUpState = 11
}

public enum VolumeKeyAdjustment {
  public static let step = 1

  public static func target(
    for action: VolumeMediaKeyAction,
    current: Int,
    maximum: Int
  ) -> Int {
    let delta =
      switch action {
      case .increase:
        step
      case .decrease:
        -step
      }

    return min(max(current + delta, 0), max(maximum, 0))
  }
}
