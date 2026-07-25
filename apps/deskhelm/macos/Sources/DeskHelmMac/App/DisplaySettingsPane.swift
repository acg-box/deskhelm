import DeskHelmAppCore
import SwiftUI

@MainActor
struct DisplaySettingsPane: View {
  let store: VolumeStore

  var body: some View {
    Section {
      DisplaySettingsView(store: store)
        .padding(.vertical, 4)
    } header: {
      Text("Display")
    } footer: {
      Text("Audio volume only · DDC/CI VCP 0x62")
    }
    .task {
      store.requestRefresh()
    }
  }
}
