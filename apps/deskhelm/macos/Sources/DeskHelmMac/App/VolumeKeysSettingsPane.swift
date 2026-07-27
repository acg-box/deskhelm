import DeskHelmAppCore
import SwiftUI

@MainActor
struct VolumeKeysSettingsPane: View {
  @Bindable private var state: VolumeKeyFeatureState
  @Bindable private var permission: AccessibilityPermission
  private let controller: VolumeKeyController

  init(
    state: VolumeKeyFeatureState,
    permission: AccessibilityPermission,
    controller: VolumeKeyController
  ) {
    self.state = state
    self.permission = permission
    self.controller = controller
  }

  var body: some View {
    Section {
      SettingsRow(
        symbolName: "keyboard",
        title: "Keyboard Volume Control",
        subtitle: "Intercept volume keys only while LG is the audio output."
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { state.isRequested },
            set: { controller.setEnabled($0) }
          )
        )
        .labelsHidden()
        .accessibilityLabel("Keyboard volume control")
      }

      if let message = state.statusMessage {
        Label(message, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        Image(
          systemName: permission.isGranted
            ? "checkmark.circle.fill"
            : "exclamationmark.circle"
        )
        .foregroundStyle(permission.isGranted ? Color.green : Color.secondary)

        Text(
          permission.isGranted
            ? "Accessibility access is ready"
            : "Accessibility access is required"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)

        Spacer()

        if !permission.isGranted {
          Button("Request Access") {
            permission.request(prompt: true)
          }
          .controlSize(.small)

          Button("Open Settings") {
            permission.openSystemSettings()
          }
          .controlSize(.small)
        }
      }

      if !permission.isGranted {
        HStack(spacing: 8) {
          if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            PermissionAppDragSource()
              .fixedSize()
          }

          Text("Drag DeskHelm into Accessibility if macOS does not add it.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Spacer()

          Button {
            permission.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .controlSize(.small)
          .help("Refresh Accessibility permission")
          .accessibilityLabel("Refresh Accessibility permission")
        }
      }
    } header: {
      Text("Volume Keys")
    } footer: {
      Text(
        "DeskHelm reads media-key events only. Non-LG audio outputs pass "
          + "through to macOS."
      )
    }
  }
}
