import AppKit
import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
  @Bindable private var launchAtLogin: LaunchAtLoginController

  init(launchAtLogin: LaunchAtLoginController) {
    self.launchAtLogin = launchAtLogin
  }

  var body: some View {
    Section {
      SettingsRow(
        symbolName: "power",
        title: "Open at Login",
        subtitle: launchAtLoginDescription
      ) {
        Toggle(
          "",
          isOn: Binding(
            get: { launchAtLogin.state.isOn },
            set: { launchAtLogin.setEnabled($0) }
          )
        )
        .labelsHidden()
        .accessibilityLabel("Open DeskHelm at login")
      }

      if launchAtLogin.state == .requiresApproval {
        HStack {
          Label(
            "macOS needs your approval before DeskHelm can start.",
            systemImage: "exclamationmark.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          Spacer()

          Button("Open Login Items") {
            openLoginItemsSettings()
          }
          .controlSize(.small)
        }
      }
    } header: {
      Text("General")
    } footer: {
      if case .error(let message, _) = launchAtLogin.state {
        Text(message)
          .foregroundStyle(Color.red)
      }
    }
  }

  private var launchAtLoginDescription: String {
    switch launchAtLogin.state {
    case .enabled:
      "Starts automatically after you sign in."
    case .requiresApproval:
      "Registration is waiting for approval."
    case .notRegistered:
      "Starts only when you open the app."
    case .error:
      "macOS could not update the login item."
    }
  }

  private func openLoginItemsSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
