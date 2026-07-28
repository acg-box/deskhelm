import Foundation

package struct VolumeLevelPresentation: Equatable, Sendable {
  package let level: Double
  package let maximum: Double

  package init(level: Double, maximum: Double) {
    self.maximum = max(maximum, 1)
    self.level = min(max(level, 0), self.maximum)
  }

  package var fraction: Double {
    level / maximum
  }

  package var roundedLevel: Int {
    Int(level.rounded())
  }

  package var lowerLevel: Int {
    Int(level.rounded(.down))
  }

  package var upperLevel: Int {
    min(lowerLevel + 1, Int(maximum.rounded(.down)))
  }

  package var transitionProgress: Double {
    level - Double(lowerLevel)
  }

  package var rollingDigits: [VolumeLevelRollingDigitPresentation] {
    let digitCount = decimalDigitCount(
      for: Int(maximum.rounded(.down))
    )
    let lowerDigits = digits(for: lowerLevel, count: digitCount)
    let upperDigits = digits(for: upperLevel, count: digitCount)

    return zip(lowerDigits, upperDigits).map {
      VolumeLevelRollingDigitPresentation(
        lowerDigit: $0,
        upperDigit: $1
      )
    }
  }

  private func digits(
    for value: Int,
    count: Int
  ) -> [Int?] {
    var digits = [Int?](repeating: nil, count: count)
    var remaining = max(value, 0)
    var index = count - 1

    repeat {
      digits[index] = remaining % 10
      remaining /= 10
      index -= 1
    } while remaining > 0 && index >= 0

    return digits
  }

  private func decimalDigitCount(for value: Int) -> Int {
    var remaining = max(value, 0)
    var count = 1

    while remaining >= 10 {
      remaining /= 10
      count += 1
    }

    return count
  }
}

package struct VolumeLevelRollingDigitPresentation: Equatable, Sendable {
  package let lowerDigit: Int?
  package let upperDigit: Int?

  package var isAnimated: Bool {
    lowerDigit != upperDigit
  }
}
