import Foundation

public struct VolumeReading: Equatable, Sendable {
  public let display: String
  public let current: Int
  public let maximum: Int

  public init(display: String, current: Int, maximum: Int) {
    self.display = display
    self.current = current
    self.maximum = maximum
  }
}

public enum VolumeControlError: LocalizedError, Equatable, Sendable {
  case invalidLevel(Int)
  case runtime(String)
  case invalidArgument(String)
  case corePanic(String)
  case invalidResponse(String)
  case unknownStatus(Int32, String)

  public var errorDescription: String? {
    switch self {
    case .invalidLevel(let level):
      "Volume \(level) is outside the supported range 0–100."
    case .runtime(let message),
      .invalidArgument(let message),
      .corePanic(let message),
      .invalidResponse(let message):
      message
    case .unknownStatus(let status, let message):
      "DeskHelm core returned status \(status): \(message)"
    }
  }
}
