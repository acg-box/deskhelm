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
}
