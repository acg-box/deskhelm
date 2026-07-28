import DeskHelmAppCore
import SwiftUI

@MainActor
struct VolumeKeysSettingsPane: View {
  @Bindable private var state: VolumeKeyFeatureState
  @Bindable private var permission: AccessibilityPermission
  private let presentPermissionGuide: @MainActor () -> Void

  init(
    state: VolumeKeyFeatureState,
    permission: AccessibilityPermission,
    presentPermissionGuide: @escaping @MainActor () -> Void
  ) {
    self.state = state
    self.permission = permission
    self.presentPermissionGuide = presentPermissionGuide
  }

  var body: some View {
    Section {
      SettingsRow(
        symbolName: statusSymbolName,
        title: statusTitle,
        subtitle: statusDescription
      ) {
        statusControl
      }
    } header: {
      Text("Volume Keys")
    } footer: {
      Text(
        "DeskHelm intercepts volume keys only while the matching LG display "
          + "is the audio output. Other outputs pass through to macOS."
      )
    }
  }

  private var needsAccessibilityAccess: Bool {
    !permission.isGranted || state.phase == .permissionRequired
  }

  private var statusSymbolName: String {
    if needsAccessibilityAccess {
      return "accessibility"
    }

    switch state.phase {
    case .disabled, .enabling:
      return "keyboard"
    case .permissionRequired:
      return "accessibility"
    case .enabled:
      return "keyboard.fill"
    case .unavailable:
      return "pause.circle"
    case .failed:
      return "exclamationmark.triangle"
    }
  }

  private var statusTitle: String {
    if needsAccessibilityAccess {
      return "Accessibility Access"
    }

    switch state.phase {
    case .disabled, .enabling, .permissionRequired:
      return "Starting Volume Keys"
    case .enabled:
      return "Volume Keys Active"
    case .unavailable:
      return "Volume Keys Paused"
    case .failed:
      return "Volume Keys Unavailable"
    }
  }

  private var statusDescription: String {
    if needsAccessibilityAccess {
      return "Required once to control the matching LG display."
    }

    switch state.phase {
    case .disabled:
      return "Preparing keyboard volume control…"
    case .enabling, .permissionRequired:
      return "Checking the display connection…"
    case .enabled:
      return "Ready for the matching LG audio output."
    case .unavailable(let message), .failed(let message):
      return message
    }
  }

  @ViewBuilder
  private var statusControl: some View {
    if needsAccessibilityAccess {
      Button("Grant") {
        presentPermissionGuide()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    } else {
      switch state.phase {
      case .disabled, .enabling, .permissionRequired, .unavailable:
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Starting volume-key control")
      case .enabled:
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .accessibilityLabel("Volume keys active")
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title3)
          .foregroundStyle(.orange)
          .accessibilityLabel("Volume keys unavailable")
      }
    }
  }
}
