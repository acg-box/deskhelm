import Foundation

public enum VolumeMediaKeyAction: Equatable, Sendable {
  case increase
  case decrease
}

public struct VolumeMediaKeyEvent: Equatable, Sendable {
  public let action: VolumeMediaKeyAction
  public let isPressed: Bool

  public init(action: VolumeMediaKeyAction, isPressed: Bool) {
    self.action = action
    self.isPressed = isPressed
  }
}

public enum VolumeMediaKeyDisposition: Equatable, Sendable {
  case passThrough
  case consume
  case consumeAndDispatch(VolumeMediaKeyAction)
}

public enum VolumeMediaKeyRoutingPolicy {
  public static func disposition(
    for event: VolumeMediaKeyEvent,
    outputMatchesTarget: Bool
  ) -> VolumeMediaKeyDisposition {
    guard outputMatchesTarget else {
      return .passThrough
    }

    return event.isPressed
      ? .consumeAndDispatch(event.action)
      : .consume
  }
}

public enum VolumeMediaKeyDecoder {
  public static func decode(
    subtype: Int16,
    data1: Int
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
      return VolumeMediaKeyEvent(action: action, isPressed: true)
    case keyUpState:
      return VolumeMediaKeyEvent(action: action, isPressed: false)
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
