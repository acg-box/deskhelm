import SwiftUI

@MainActor
struct AboutSettingsPane: View {
  @ObservedObject private var softwareUpdater: SoftwareUpdater

  init(softwareUpdater: SoftwareUpdater) {
    _softwareUpdater = ObservedObject(wrappedValue: softwareUpdater)
  }

  var body: some View {
    let snapshot = softwareUpdater.snapshot()

    Section {
      SettingsRow(
        symbolName: "arrow.triangle.2.circlepath",
        title: "Automatic Updates",
        subtitle: snapshot.modeDescription
      ) {
        Picker(
          "",
          selection: Binding(
            get: { snapshot.mode },
            set: { mode in
              softwareUpdater.setMode(mode)
            }
          )
        ) {
          ForEach(SoftwareUpdater.Mode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!snapshot.isConfigured)
        .accessibilityLabel("Automatic updates")
      }

      SettingsRow(
        symbolName: "tag",
        title: snapshot.isConfigured ? "Release Version" : "GitHub Releases",
        subtitle: snapshot.isConfigured
          ? "Sparkle checks the signed DeskHelm appcast."
          : "This build has no signed appcast configuration."
      ) {
        Button(
          snapshot.isConfigured
            ? "Check Now"
            : "View Releases"
        ) {
          softwareUpdater.checkForUpdates()
        }
        .disabled(!snapshot.canCheckForUpdates)
        .controlSize(.small)
      }
    } header: {
      Text("Updates")
    } footer: {
      HStack {
        Text("DeskHelm \(snapshot.currentVersion)")
        Spacer()
        Link("Source Code", destination: Self.sourceURL)
      }
    }
  }

  private static let sourceURL: URL = {
    guard let url = URL(string: "https://github.com/acg-box/deskhelm") else {
      preconditionFailure("Invalid DeskHelm source URL.")
    }
    return url
  }()
}
