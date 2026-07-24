import Testing

@testable import DeskHelmAppCore

@Suite("Volume HUD state")
@MainActor
struct VolumeHUDStateTests {
  @Test("Volume levels stay inside the supported range")
  func clampsVolumeLevels() {
    let state = VolumeHUDState(level: -1)
    #expect(state.content == .level(0))

    state.show(level: 101)
    #expect(state.content == .level(100))
  }

  @Test("Level and error content replace one another atomically")
  func switchesContent() {
    let state = VolumeHUDState(level: 42)

    state.show(message: "Communication failed.")
    #expect(state.content == .message("Communication failed."))

    state.show(level: 43)
    #expect(state.content == .level(43))
  }
}
