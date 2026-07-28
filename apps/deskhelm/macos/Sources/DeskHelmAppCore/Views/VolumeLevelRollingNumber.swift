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
    ZStack {
      if presentation.isAnimated {
        digit(presentation.lowerDigit)
          .offset(y: -CGFloat(progress) * digitHeight)

        digit(presentation.upperDigit)
          .offset(y: CGFloat(1 - progress) * digitHeight)
      } else {
        digit(presentation.lowerDigit)
      }
    }
    .frame(
      width: 10,
      height: digitHeight,
      alignment: .trailing
    )
    .clipped()
  }

  private var digitHeight: CGFloat { 22 }

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
