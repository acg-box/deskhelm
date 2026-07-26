import AppKit
import Foundation
import Testing

@testable import DeskHelmMac

@Suite("Volume feedback preference policy")
struct VolumeFeedbackPreferencePolicyTests {
  @Test("An absent preference defaults to enabled")
  func absentPreference() {
    #expect(
      VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: nil,
        invertingSystemPreference: false
      )
    )
  }

  @Test("A malformed preference defaults to enabled")
  func malformedPreference() {
    #expect(
      VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: "invalid",
        invertingSystemPreference: false
      )
    )
  }

  @Test("The system preference enables or disables feedback")
  func systemPreference() {
    #expect(
      VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: NSNumber(value: true),
        invertingSystemPreference: false
      )
    )
    #expect(
      !VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: NSNumber(value: false),
        invertingSystemPreference: false
      )
    )
  }

  @Test("Shift inversion applies XOR to the system preference")
  func shiftInversion() {
    #expect(
      !VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: NSNumber(value: true),
        invertingSystemPreference: true
      )
    )
    #expect(
      VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: NSNumber(value: false),
        invertingSystemPreference: true
      )
    )
  }

  @Test("Only standalone Shift inverts the system preference")
  func modifierPolicy() {
    #expect(
      VolumeFeedbackModifierPolicy.shouldInvertSystemPreference(
        for: [.shift]
      )
    )
    #expect(
      VolumeFeedbackModifierPolicy.shouldInvertSystemPreference(
        for: [.shift, .capsLock]
      )
    )

    for modifiers: NSEvent.ModifierFlags in [
      [],
      [.option],
      [.shift, .option],
      [.shift, .control],
      [.shift, .command],
      [.shift, .option, .control, .command],
    ] {
      #expect(
        !VolumeFeedbackModifierPolicy.shouldInvertSystemPreference(
          for: modifiers
        )
      )
    }
  }

  @Test("Feedback assets use the first loadable fallback")
  func feedbackAssetFallbackOrder() {
    var attempted: [String] = []

    let selected: String? = VolumeFeedbackAssetSelection.firstLoadable(
      paths: ["private", "framework", "public"]
    ) { path in
      attempted.append(path)
      return path == "public" ? path : nil
    }

    #expect(selected == "public")
    #expect(attempted == ["private", "framework", "public"])
  }
}
