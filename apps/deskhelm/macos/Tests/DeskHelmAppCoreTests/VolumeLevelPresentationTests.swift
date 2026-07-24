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
}
