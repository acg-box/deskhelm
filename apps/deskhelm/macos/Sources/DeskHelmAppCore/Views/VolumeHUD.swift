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
    switch state.content {
    case .level(let level):
      HStack(spacing: 14) {
        Image(systemName: symbolName(for: level))
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 22)
          .accessibilityHidden(true)

        ProgressView(value: Double(level), total: 100)
          .progressViewStyle(.linear)
          .tint(.primary)

        Text(level, format: .number)
          .font(.body.monospacedDigit().weight(.medium))
          .frame(width: 30, alignment: .trailing)
          .contentTransition(.numericText(value: Double(level)))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(width: 300)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("External display volume")
      .accessibilityValue("\(level) percent")
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
