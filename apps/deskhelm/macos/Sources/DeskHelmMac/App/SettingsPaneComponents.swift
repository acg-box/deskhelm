import SwiftUI

struct SettingsRow<Control: View>: View {
  let symbolName: String
  let title: String
  let subtitle: String
  @ViewBuilder let control: Control

  init(
    symbolName: String,
    title: String,
    subtitle: String,
    @ViewBuilder control: () -> Control
  ) {
    self.symbolName = symbolName
    self.title = title
    self.subtitle = subtitle
    self.control = control()
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbolName)
        .symbolRenderingMode(.hierarchical)
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .layoutPriority(1)

      Spacer(minLength: 12)
      control
    }
    .frame(minHeight: 38)
  }
}
