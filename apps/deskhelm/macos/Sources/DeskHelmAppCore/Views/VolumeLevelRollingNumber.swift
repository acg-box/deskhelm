import SwiftUI

@MainActor
struct VolumeLevelRollingNumber: View {
  let presentation: VolumeLevelPresentation
  let weight: Font.Weight

  var body: some View {
    GeometryReader { proxy in
      let progress = presentation.transitionProgress

      ZStack(alignment: .trailing) {
        number(presentation.lowerLevel)
          .opacity(1 - progress)
          .offset(y: -progress * proxy.size.height)

        if presentation.upperLevel != presentation.lowerLevel {
          number(presentation.upperLevel)
            .opacity(progress)
            .offset(y: (1 - progress) * proxy.size.height)
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .trailing
      )
    }
    .frame(width: 30, height: 22)
    .clipped()
    .accessibilityHidden(true)
  }

  private func number(_ level: Int) -> some View {
    Text(level, format: .number)
      .font(.body.monospacedDigit().weight(weight))
  }
}
