import Testing

@testable import DeskHelmAppCore

@Suite("Volume level presentation")
struct VolumeLevelPresentationTests {
  @Test("Track fraction and number use the same presentation scalar")
  func sharedScalar() {
    let presentation = VolumeLevelPresentation(level: 37.6, maximum: 100)

    #expect(abs(presentation.fraction - 0.376) < 0.000_1)
    #expect(presentation.roundedLevel == 38)
    #expect(presentation.lowerLevel == 37)
    #expect(presentation.upperLevel == 38)
    #expect(abs(presentation.transitionProgress - 0.6) < 0.000_1)
  }

  @Test("Presentation clamps invalid visual levels")
  func clamping() {
    let below = VolumeLevelPresentation(level: -1, maximum: 100)
    let above = VolumeLevelPresentation(level: 101, maximum: 100)

    #expect(below.level == 0)
    #expect(below.fraction == 0)
    #expect(above.level == 100)
    #expect(above.fraction == 1)
    #expect(above.lowerLevel == 100)
    #expect(above.upperLevel == 100)
    #expect(above.transitionProgress == 0)
  }

  @Test("Non-positive maximum stays safe")
  func safeMaximum() {
    let presentation = VolumeLevelPresentation(level: 1, maximum: 0)

    #expect(presentation.maximum == 1)
    #expect(presentation.level == 1)
    #expect(presentation.fraction == 1)
  }

  @Test("Rolling digits animate only changed places")
  func rollingDigits() {
    let normalStep = VolumeLevelPresentation(level: 14.5, maximum: 100)
    #expect(normalStep.rollingDigits.map(\.lowerDigit) == [nil, 1, 4])
    #expect(normalStep.rollingDigits.map(\.upperDigit) == [nil, 1, 5])
    #expect(normalStep.rollingDigits.map(\.isAnimated) == [false, false, true])

    let carry = VolumeLevelPresentation(level: 19.5, maximum: 100)
    #expect(carry.rollingDigits.map(\.lowerDigit) == [nil, 1, 9])
    #expect(carry.rollingDigits.map(\.upperDigit) == [nil, 2, 0])
    #expect(carry.rollingDigits.map(\.isAnimated) == [false, true, true])
  }

  @Test("Rolling digits preserve place value across width changes")
  func rollingDigitWidthChanges() {
    let ten = VolumeLevelPresentation(level: 9.5, maximum: 100)
    #expect(ten.rollingDigits.map(\.lowerDigit) == [nil, nil, 9])
    #expect(ten.rollingDigits.map(\.upperDigit) == [nil, 1, 0])
    #expect(ten.rollingDigits.map(\.isAnimated) == [false, true, true])

    let hundred = VolumeLevelPresentation(level: 99.5, maximum: 100)
    #expect(hundred.rollingDigits.map(\.lowerDigit) == [nil, 9, 9])
    #expect(hundred.rollingDigits.map(\.upperDigit) == [1, 0, 0])
    #expect(hundred.rollingDigits.map(\.isAnimated) == [true, true, true])

    let maximum = VolumeLevelPresentation(level: 100, maximum: 100)
    #expect(maximum.rollingDigits.map(\.lowerDigit) == [1, 0, 0])
    #expect(maximum.rollingDigits.map(\.upperDigit) == [1, 0, 0])
    #expect(maximum.rollingDigits.map(\.isAnimated) == [false, false, false])
  }
}
