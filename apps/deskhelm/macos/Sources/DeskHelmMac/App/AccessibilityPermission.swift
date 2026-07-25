import AppKit
@preconcurrency import ApplicationServices
import Observation

enum AccessibilityPermissionState: Equatable {
  case granted
  case required
}

@MainActor
@Observable
final class AccessibilityPermission {
  private(set) var state: AccessibilityPermissionState {
    didSet {
      guard state != oldValue else { return }
      stateChange?(state)
    }
  }
  @ObservationIgnored private var stateChange: (@MainActor (AccessibilityPermissionState) -> Void)?

  init() {
    state = Self.currentState
  }

  var isGranted: Bool {
    state == .granted
  }

  func onStateChange(
    _ action: @escaping @MainActor (AccessibilityPermissionState) -> Void
  ) {
    stateChange = action
  }

  @discardableResult
  func refresh() -> AccessibilityPermissionState {
    let currentState = Self.currentState
    state = currentState
    return currentState
  }

  @discardableResult
  func request(prompt: Bool) -> AccessibilityPermissionState {
    if prompt {
      let promptKey =
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let options = [promptKey: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    return refresh()
  }

  @discardableResult
  func openSystemSettings() -> Bool {
    let privacyQuery = "Privacy_Accessibility"
    let modernURLString =
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(privacyQuery)"

    if let modernURL = URL(string: modernURLString),
      NSWorkspace.shared.open(modernURL)
    {
      return true
    }

    let fallbackURLString =
      "x-apple.systempreferences:com.apple.preference.security?\(privacyQuery)"
    guard let fallbackURL = URL(string: fallbackURLString) else {
      return false
    }
    return NSWorkspace.shared.open(fallbackURL)
  }

  private static var currentState: AccessibilityPermissionState {
    AXIsProcessTrusted() ? .granted : .required
  }
}
