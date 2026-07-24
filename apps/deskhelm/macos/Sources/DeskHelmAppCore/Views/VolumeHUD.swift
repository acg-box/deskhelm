import Observation
import SwiftUI

public enum VolumeHUDContent: Equatable, Sendable {
  case level(Int)
  case message(String)
}

@MainActor
@Observable
public final class VolumeHUDState {
  public private(set) var content: VolumeHUDContent

  public init(level: Int = 0) {
    content = .level(Self.clamped(level))
  }

  public func show(level: Int) {
    content = .level(Self.clamped(level))
  }

  public func show(message: String) {
    content = .message(message)
  }

  private static func clamped(_ level: Int) -> Int {
    min(max(level, 0), 100)
  }
}

public struct VolumeHUD: View {
  @Bindable private var state: VolumeHUDState

  public init(state: VolumeHUDState) {
    self.state = state
  }

  @ViewBuilder
  public var body: some View {
    singleGlassSurface
      .environment(\.appearsActive, true)
      .padding(8)
  }

  @ViewBuilder
  private var singleGlassSurface: some View {
    if #available(macOS 26.0, *) {
      hudContent
        .glassEffect(
          .clear.interactive(),
          in: Capsule()
        )
    } else {
      hudContent
        .background(
          .regularMaterial,
          in: Capsule()
        )
    }
  }

  @ViewBuilder
  private var hudContent: some View {
    switch state.content {
    case .level(let level):
      VolumeHUDLevelContent(level: Double(level))
    case .message(let message):
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        Text(message)
          .font(.callout)
          .lineLimit(2)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      .frame(width: 300)
      .accessibilityElement(children: .combine)
    }
  }
}

@MainActor
private struct VolumeHUDLevelContent: View, Animatable {
  var level: Double

  nonisolated var animatableData: Double {
    get { level }
    set { level = newValue }
  }

  var body: some View {
    let presentation = VolumeLevelPresentation(level: level, maximum: 100)

    HStack(spacing: 14) {
      Image(systemName: symbolName(for: presentation.roundedLevel))
        .font(.system(size: 17, weight: .semibold))
        .frame(width: 22)
        .accessibilityHidden(true)

      GeometryReader { proxy in
        Capsule()
          .fill(.tertiary)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(.primary.opacity(0.72))
              .frame(width: proxy.size.width * presentation.fraction)
          }
      }
      .frame(height: 5)

      VolumeLevelRollingNumber(
        presentation: presentation,
        weight: .medium
      )
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(width: 300)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("External display volume")
    .accessibilityValue("\(presentation.roundedLevel) percent")
  }

  private func symbolName(for level: Int) -> String {
    switch level {
    case 0:
      "speaker.slash.fill"
    case 1...33:
      "speaker.wave.1.fill"
    case 34...66:
      "speaker.wave.2.fill"
    default:
      "speaker.wave.3.fill"
    }
  }
}
