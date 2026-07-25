import Observation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
  case enabled
  case requiresApproval
  case notRegistered
  case error(message: String, isOn: Bool)

  var isOn: Bool {
    switch self {
    case .enabled, .requiresApproval:
      true
    case .notRegistered:
      false
    case .error(_, let isOn):
      isOn
    }
  }
}

@MainActor
@Observable
final class LaunchAtLoginController {
  private(set) var state: LaunchAtLoginState {
    didSet {
      guard state != oldValue else { return }
      stateChange?(state)
    }
  }
  @ObservationIgnored private var stateChange: (@MainActor (LaunchAtLoginState) -> Void)?

  init() {
    state = Self.currentState
  }

  func onStateChange(
    _ action: @escaping @MainActor (LaunchAtLoginState) -> Void
  ) {
    stateChange = action
  }

  func refresh() {
    state = Self.currentState
  }

  func setEnabled(_ isEnabled: Bool) {
    let service = SMAppService.mainApp
    let initialState = Self.state(for: service.status)

    do {
      if isEnabled {
        switch initialState {
        case .enabled, .requiresApproval:
          break
        case .notRegistered:
          try service.register()
        case .error:
          try service.register()
        }
      } else {
        switch initialState {
        case .enabled, .requiresApproval:
          try service.unregister()
        case .notRegistered:
          break
        case .error:
          try service.unregister()
        }
      }

      refresh()
    } catch {
      state = .error(
        message: error.localizedDescription,
        isOn: initialState.isOn
      )
    }
  }

  private static var currentState: LaunchAtLoginState {
    state(for: SMAppService.mainApp.status)
  }

  private static func state(
    for status: SMAppService.Status
  ) -> LaunchAtLoginState {
    switch status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .error(
        message: "DeskHelm.app is not available to register at login.",
        isOn: false
      )
    @unknown default:
      .error(
        message: "macOS returned an unknown login item status.",
        isOn: false
      )
    }
  }
}
