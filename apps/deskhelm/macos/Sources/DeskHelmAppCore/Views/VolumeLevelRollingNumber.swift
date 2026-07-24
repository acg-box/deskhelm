import SwiftUI

@MainActor
struct VolumeLevelRollingNumber: View {
  let presentation: VolumeLevelPresentation
  let weight: Font.Weight

  var body: some View {
    let digits = presentation.rollingDigits

    HStack(spacing: 0) {
      ForEach(digits.indices, id: \.self) { index in
        VolumeLevelRollingDigit(
          presentation: digits[index],
          progress: presentation.transitionProgress,
          weight: weight
        )
      }
    }
    .frame(width: 30, height: 22, alignment: .trailing)
    .clipped()
    .accessibilityHidden(true)
  }
}

@MainActor
private struct VolumeLevelRollingDigit: View {
  let presentation: VolumeLevelRollingDigitPresentation
  let progress: Double
  let weight: Font.Weight

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        if presentation.isAnimated {
          digit(presentation.lowerDigit)
            .offset(y: -progress * proxy.size.height)

          digit(presentation.upperDigit)
            .offset(y: (1 - progress) * proxy.size.height)
        } else {
          digit(presentation.lowerDigit)
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .trailing
      )
    }
    .frame(width: 10, height: 22)
    .clipped()
  }

  @ViewBuilder
  private func digit(_ value: Int?) -> some View {
    if let value {
      Text(String(value))
        .font(.body.monospacedDigit().weight(weight))
    } else {
      Color.clear
    }
  }
}
