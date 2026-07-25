import SwiftUI

@MainActor
struct AboutSettingsPane: View {
  private let softwareUpdater: SoftwareUpdater
  @State private var snapshot: SoftwareUpdater.Snapshot

  init(softwareUpdater: SoftwareUpdater) {
    self.softwareUpdater = softwareUpdater
    _snapshot = State(initialValue: softwareUpdater.snapshot())
  }

  var body: some View {
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
              refresh()
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
          refresh()
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
    .onAppear {
      refresh()
    }
  }

  private func refresh() {
    snapshot = softwareUpdater.snapshot()
  }

  private static let sourceURL: URL = {
    guard let url = URL(string: "https://github.com/acg-box/deskhelm") else {
      preconditionFailure("Invalid DeskHelm source URL.")
    }
    return url
  }()
}
