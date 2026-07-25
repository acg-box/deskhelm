import SwiftUI

public struct DisplaySettingsView: View {
  @Bindable private var store: VolumeStore
  @State private var isEditing = false

  public init(store: VolumeStore) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      volumeControl
      errorStatus
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("LG 39GX950B")
          .font(.headline)
        Text("USB-C · DDC/CI")
          .font(.caption)
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
        store.requestRefresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .font(.system(size: 15, weight: .semibold))
      .buttonStyle(.plain)
      .frame(width: 24, height: 24)
      .disabled(store.isRefreshInProgress)
      .help("Read volume from the display")
      .accessibilityLabel("Refresh monitor volume")
      .accessibilityIdentifier("refresh-volume")
    }
  }

  private var volumeControl: some View {
    VolumeLevelControl(
      level: store.draftLevel,
      maximum: Double(store.maximumLevel),
      isEnabled: store.isAdjustable,
      isEditing: isEditing,
      onChange: { level in
        store.updateDraft(level)
        store.queueDraftApply()
      },
      onEditingChanged: { editing in
        isEditing = editing
        if !editing {
          Task { await store.applyDraft() }
        }
      },
      onAccessibilityAdjustment: { direction in
        let delta = direction == .increment ? 1.0 : -1.0
        store.updateDraft(store.draftLevel + delta)
        store.queueDraftApply()
      }
    )
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

}

@MainActor
private struct VolumeLevelControl: View, Animatable {
  var level: Double
  let maximum: Double
  let isEnabled: Bool
  let isEditing: Bool
  let onChange: (Double) -> Void
  let onEditingChanged: (Bool) -> Void
  let onAccessibilityAdjustment: (AccessibilityAdjustmentDirection) -> Void

  nonisolated var animatableData: Double {
    get { level }
    set { level = newValue }
  }

  var body: some View {
    let presentation = VolumeLevelPresentation(
      level: level,
      maximum: maximum
    )

    HStack(spacing: 12) {
      Image(systemName: "speaker.fill")
        .foregroundStyle(.secondary)
        .font(.system(size: 16, weight: .semibold))
        .accessibilityHidden(true)

      track(presentation)
        .frame(height: 18)
        .contentShape(Rectangle())

      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
        .font(.system(size: 16, weight: .semibold))
        .accessibilityHidden(true)

      Group {
        if isEnabled {
          VolumeLevelRollingNumber(
            presentation: presentation,
            weight: isEditing ? .semibold : .regular
          )
        } else {
          Text("—")
            .font(
              .body.monospacedDigit().weight(
                isEditing ? .semibold : .regular
              )
            )
            .frame(width: 30, height: 22)
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(isEditing ? .primary : .secondary)
      .accessibilityIdentifier("draft-volume")
    }
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Monitor volume")
    .accessibilityValue(
      isEnabled ? "\(presentation.roundedLevel) percent" : "Unavailable"
    )
    .accessibilityIdentifier("volume-slider")
    .disabled(!isEnabled)
    .focusable(isEnabled)
    .onKeyPress(.leftArrow) {
      adjustFromKeyboard(.decrement)
    }
    .onKeyPress(.downArrow) {
      adjustFromKeyboard(.decrement)
    }
    .onKeyPress(.rightArrow) {
      adjustFromKeyboard(.increment)
    }
    .onKeyPress(.upArrow) {
      adjustFromKeyboard(.increment)
    }
    .accessibilityAdjustableAction { direction in
      guard isEnabled else { return }
      switch direction {
      case .increment, .decrement:
        onAccessibilityAdjustment(direction)
      @unknown default:
        return
      }
    }
  }

  private func track(
    _ presentation: VolumeLevelPresentation
  ) -> some View {
    GeometryReader { proxy in
      let travel = max(proxy.size.width - thumbDiameter, 0)
      let thumbX = travel * presentation.fraction

      ZStack(alignment: .leading) {
        Capsule()
          .fill(.tertiary)
          .frame(height: 5)

        Capsule()
          .fill(.primary.opacity(0.72))
          .frame(width: thumbX + thumbDiameter / 2, height: 5)

        Circle()
          .fill(.primary)
          .frame(width: thumbDiameter, height: thumbDiameter)
          .offset(x: thumbX)
      }
      .frame(maxHeight: .infinity, alignment: .center)
      .contentShape(Rectangle())
      .gesture(dragGesture(width: proxy.size.width))
    }
  }

  private func dragGesture(width: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard isEnabled else { return }
        if !isEditing {
          onEditingChanged(true)
        }
        let travel = max(width - thumbDiameter, 1)
        let proposed = min(
          max((value.location.x - thumbDiameter / 2) / travel, 0),
          1
        )
        onChange(proposed * max(maximum, 1))
      }
      .onEnded { _ in
        guard isEnabled else { return }
        onEditingChanged(false)
      }
  }

  private var thumbDiameter: Double {
    14
  }

  private func adjustFromKeyboard(
    _ direction: AccessibilityAdjustmentDirection
  ) -> KeyPress.Result {
    guard isEnabled else { return .ignored }
    onAccessibilityAdjustment(direction)
    return .handled
  }
}
