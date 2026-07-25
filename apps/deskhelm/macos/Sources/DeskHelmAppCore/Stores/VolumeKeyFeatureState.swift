import Foundation
import Observation

@MainActor
@Observable
public final class VolumeKeyFeatureState {
  public enum Phase: Equatable, Sendable {
    case disabled
    case enabling
    case permissionRequired
    case enabled
    case failed(String)
  }

  public private(set) var phase: Phase = .disabled

  public init() {}

  public var isEnabled: Bool {
    phase == .enabled
  }

  public var isRequested: Bool {
    switch phase {
    case .enabling, .enabled:
      true
    case .disabled, .permissionRequired, .failed:
      false
    }
  }

  public var statusMessage: String? {
    switch phase {
    case .disabled, .enabled:
      nil
    case .enabling:
      "Enabling keyboard volume control…"
    case .permissionRequired:
      "Allow DeskHelm in Privacy & Security > Accessibility, then enable volume keys again."
    case .failed(let message):
      message
    }
  }

  public func update(to phase: Phase) {
    self.phase = phase
  }
}

public struct VolumeKeyEnableRequestState: Sendable {
  public struct Token: Equatable, Sendable {
    fileprivate let generation: UInt
  }

  private var generation: UInt = 0
  private var activeGeneration: UInt?

  public init() {}

  public var hasActiveRequest: Bool {
    activeGeneration != nil
  }

  public mutating func begin() -> Token {
    generation &+= 1
    activeGeneration = generation
    return Token(generation: generation)
  }

  public func isCurrent(_ token: Token) -> Bool {
    activeGeneration == token.generation
  }

  @discardableResult
  public mutating func finish(_ token: Token) -> Bool {
    guard isCurrent(token) else { return false }
    activeGeneration = nil
    return true
  }

  public mutating func cancel() {
    activeGeneration = nil
  }
}
