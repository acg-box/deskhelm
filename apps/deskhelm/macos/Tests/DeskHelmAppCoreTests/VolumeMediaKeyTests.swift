import Testing

@testable import DeskHelmAppCore

@Suite("Volume media keys")
struct VolumeMediaKeyTests {
  @Test("Decoder preserves volume key press, system repeat, release, and feedback")
  func decodeVolumeKeyStates() {
    let systemRepeatFlag = 1

    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 0, state: 10)
      )
        == VolumeMediaKeyEvent(action: .increase, state: .pressed)
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 1, state: 10) | systemRepeatFlag,
        shouldInvertFeedback: true
      )
        == VolumeMediaKeyEvent(
          action: .decrease,
          state: .pressed,
          shouldInvertFeedback: true
        )
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 0, state: 11),
        shouldInvertFeedback: true
      )
        == VolumeMediaKeyEvent(
          action: .increase,
          state: .released,
          shouldInvertFeedback: true
        )
    )
  }

  @Test("Decoder rejects mute and unrelated system events")
  func rejectUnrelatedEvents() {
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 7,
        data1: payload(keyCode: 0, state: 10)
      ) == nil
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 7, state: 10)
      ) == nil
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 0, state: 12)
      ) == nil
    )
  }

  @Test("Target output consumes and dispatches the full event stream")
  func targetOutputDisposition() {
    let press = VolumeMediaKeyEvent(
      action: .increase,
      state: .pressed,
      shouldInvertFeedback: true
    )
    let release = VolumeMediaKeyEvent(
      action: .increase,
      state: .released,
      shouldInvertFeedback: true
    )

    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: press,
        outputMatchesTarget: true
      ) == .consumeAndDispatch(press)
    )
    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: release,
        outputMatchesTarget: true
      ) == .consumeAndDispatch(release)
    )
  }

  @Test("Non-target output passes through and dispatches the full event stream")
  func nonTargetOutputDisposition() {
    let press = VolumeMediaKeyEvent(
      action: .decrease,
      state: .pressed
    )
    let release = VolumeMediaKeyEvent(
      action: .decrease,
      state: .released
    )

    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: press,
        outputMatchesTarget: false
      ) == .passThroughAndDispatch(press)
    )
    #expect(
      VolumeMediaKeyRoutingPolicy.disposition(
        for: release,
        outputMatchesTarget: false
      ) == .passThroughAndDispatch(release)
    )
  }

  @Test("Adjustment uses one-point steps and clamps to the display range")
  func adjustmentBounds() {
    #expect(
      VolumeKeyAdjustment.target(
        for: .increase,
        current: 42,
        maximum: 100
      ) == 43
    )
    #expect(
      VolumeKeyAdjustment.target(
        for: .decrease,
        current: 42,
        maximum: 100
      ) == 41
    )
    #expect(
      VolumeKeyAdjustment.target(
        for: .increase,
        current: 100,
        maximum: 100
      ) == 100
    )
    #expect(
      VolumeKeyAdjustment.target(
        for: .decrease,
        current: 0,
        maximum: 100
      ) == 0
    )
  }

  private func payload(
    keyCode: UInt32,
    state: UInt32
  ) -> Int {
    Int((keyCode << 16) | (state << 8))
  }
}
