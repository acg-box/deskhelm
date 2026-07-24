import Testing

@testable import DeskHelmAppCore

@Suite("Volume media keys")
struct VolumeMediaKeyTests {
  @Test("Decoder accepts volume key press, system repeat, and release")
  func decodeVolumeKeyStates() {
    let systemRepeatFlag = 1

    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 0, state: 10)
      )
        == VolumeMediaKeyEvent(action: .increase, isPressed: true)
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 1, state: 10) | systemRepeatFlag
      )
        == VolumeMediaKeyEvent(action: .decrease, isPressed: true)
    )
    #expect(
      VolumeMediaKeyDecoder.decode(
        subtype: 8,
        data1: payload(keyCode: 0, state: 11)
      )
        == VolumeMediaKeyEvent(action: .increase, isPressed: false)
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
