import Testing

@testable import DeskHelmAppCore

@Suite("Volume level animation")
struct VolumeLevelAnimationTests {
  @Test("Hidden, first, reduced-motion, and sub-frame updates are immediate")
  func immediateUpdates() {
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: 1,
        currentUpdateUptime: 1.2,
        isVisible: false,
        reduceMotion: false
      ) == .immediate
    )
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: nil,
        currentUpdateUptime: 1.2,
        isVisible: true,
        reduceMotion: false
      ) == .immediate
    )
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: 1,
        currentUpdateUptime: 1.2,
        isVisible: true,
        reduceMotion: true
      ) == .immediate
    )
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: 1,
        currentUpdateUptime: 1.01,
        isVisible: true,
        reduceMotion: false
      ) == .immediate
    )
  }

  @Test("A visible menu can animate its first isolated update")
  func firstVisibleMenuUpdate() {
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: nil,
        currentUpdateUptime: 1.2,
        isVisible: true,
        reduceMotion: false,
        animatesFirstUpdate: true
      )
        == .linear(duration: 0.08, isContinuous: false)
    )
  }

  @Test("Continuous input completes a short linear animation before the next update")
  func continuousInput() {
    let plan = VolumeLevelAnimationPolicy.plan(
      previousUpdateUptime: 1,
      currentUpdateUptime: 1.05,
      isVisible: true,
      reduceMotion: false
    )

    guard case .linear(let duration, let isContinuous) = plan else {
      Issue.record("Expected a linear continuous-input plan.")
      return
    }

    #expect(abs(duration - 0.03) < 0.000_1)
    #expect(duration < 0.05)
    #expect(isContinuous)
  }

  @Test("Slow input uses a bounded non-continuous animation")
  func isolatedInput() {
    #expect(
      VolumeLevelAnimationPolicy.plan(
        previousUpdateUptime: 1,
        currentUpdateUptime: 1.2,
        isVisible: true,
        reduceMotion: false
      )
        == .linear(duration: 0.08, isContinuous: false)
    )
  }
}
