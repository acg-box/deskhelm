import SwiftUI

public struct VolumePanel: View {
  @Bindable private var store: VolumeStore
  @Bindable private var volumeKeyState: VolumeKeyFeatureState
  @State private var isEditing = false

  private let onQuit: () -> Void
  private let onToggleVolumeKeys: () -> Void

  public init(
    store: VolumeStore,
    volumeKeyState: VolumeKeyFeatureState,
    onToggleVolumeKeys: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.store = store
    self.volumeKeyState = volumeKeyState
    self.onToggleVolumeKeys = onToggleVolumeKeys
    self.onQuit = onQuit
  }

  public var body: some View {
    singleGlassSurface
      .padding(10)
  }

  @ViewBuilder
  private var singleGlassSurface: some View {
    if #available(macOS 26.0, *) {
      panelContent
        .glassEffect(
          .clear.interactive(),
          in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    } else {
      panelContent
        .background(
          .regularMaterial,
          in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }
  }

  private var panelContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      volumeControl
      errorStatus
      volumeKeyStatus
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(width: 360)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("LG 39GX950B")
          .font(.title3.weight(.semibold))
        Text("USB-C · DDC/CI")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .help(store.displayName)

      Spacer()

      if store.showsInitialLoadingIndicator {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Communicating with display")
      }

      Button {
        Task { await store.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .font(.system(size: 15, weight: .semibold))
      .buttonStyle(.plain)
      .frame(width: 24, height: 24)
      .disabled(store.isBusy)
      .help("Read volume from the display")
      .accessibilityLabel("Refresh monitor volume")
      .accessibilityIdentifier("refresh-volume")

      Menu {
        Button {
          onToggleVolumeKeys()
        } label: {
          Label(
            volumeKeyState.isEnabled
              ? "Disable Volume Keys"
              : "Enable Volume Keys…",
            systemImage: "keyboard"
          )
        }
        .disabled(volumeKeyState.phase == .enabling)

        Divider()

        Button {
          onQuit()
        } label: {
          Label("Quit DeskHelm", systemImage: "power")
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .font(.system(size: 16, weight: .semibold))
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 24, height: 24)
      .help("DeskHelm menu")
      .accessibilityLabel("DeskHelm menu")
    }
  }

  private var volumeControl: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.fill")
        .foregroundStyle(.secondary)
        .font(.system(size: 16, weight: .semibold))
        .accessibilityHidden(true)

      Slider(
        value: Binding(
          get: { store.draftLevel },
          set: {
            store.updateDraft($0)
            store.queueDraftApply()
          }
        ),
        in: store.sliderRange
      ) { editing in
        isEditing = editing
        if !editing {
          Task { await store.applyDraft() }
        }
      }
      .disabled(!store.isAdjustable)
      .controlSize(.large)
      .accessibilityLabel("Monitor volume")
      .accessibilityValue(accessibilityLevelText)
      .accessibilityIdentifier("volume-slider")

      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
        .font(.system(size: 16, weight: .semibold))
        .accessibilityHidden(true)

      Text(levelText)
        .font(.body.monospacedDigit().weight(isEditing ? .semibold : .regular))
        .foregroundStyle(isEditing ? .primary : .secondary)
        .frame(width: 30, alignment: .trailing)
        .contentTransition(.numericText(value: store.draftLevel))
        .accessibilityHidden(true)
        .accessibilityIdentifier("draft-volume")
    }
  }

  private var levelText: String {
    guard store.confirmedLevel != nil else {
      return "—"
    }

    return String(Int(store.draftLevel.rounded()))
  }

  private var accessibilityLevelText: String {
    guard store.confirmedLevel != nil else {
      return "Unavailable"
    }

    return "\(Int(store.draftLevel.rounded())) percent"
  }

  @ViewBuilder
  private var errorStatus: some View {
    if let errorMessage = store.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("volume-error")
    }
  }

  @ViewBuilder
  private var volumeKeyStatus: some View {
    if let message = volumeKeyState.statusMessage {
      Label(message, systemImage: "keyboard.badge.ellipsis")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("volume-key-status")
    }
  }
}
