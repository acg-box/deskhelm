import AppKit
import Foundation
import OSLog

@MainActor
protocol VolumeFeedbackPlaying: AnyObject {
  func play(
    on deviceUID: String?,
    invertingSystemPreference: Bool
  )
  func stop()
}

enum VolumeFeedbackPreferencePolicy {
  static func shouldPlay(
    globalPreferenceValue: Any?,
    invertingSystemPreference: Bool
  ) -> Bool {
    let systemPreference =
      (globalPreferenceValue as? NSNumber)?.boolValue
      ?? true
    return systemPreference != invertingSystemPreference
  }
}

enum VolumeFeedbackAssetSelection {
  static func firstLoadable<Asset>(
    paths: [String],
    load: (String) -> Asset?
  ) -> Asset? {
    for path in paths {
      if let asset = load(path) {
        return asset
      }
    }
    return nil
  }
}

@MainActor
final class VolumeFeedbackPlayer: VolumeFeedbackPlaying {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "VolumeFeedback"
  )
  private let sound: NSSound?

  init() {
    sound = Self.loadVolumeFeedbackSound()
    if sound == nil {
      logger.error(
        "macOS volume feedback sound is unavailable; feedback will be silent."
      )
    }
  }

  func play(
    on deviceUID: String?,
    invertingSystemPreference: Bool
  ) {
    stop()

    guard
      VolumeFeedbackPreferencePolicy.shouldPlay(
        globalPreferenceValue: Self.globalFeedbackPreference,
        invertingSystemPreference: invertingSystemPreference
      ),
      let sound
    else {
      return
    }

    sound.playbackDeviceIdentifier = deviceUID
    sound.currentTime = 0
    if !sound.play() {
      logger.error(
        "macOS did not start the volume feedback sound."
      )
    }
  }

  func stop() {
    guard let sound else { return }
    sound.stop()
    sound.currentTime = 0
  }

  private static var globalFeedbackPreference: Any? {
    UserDefaults.standard.persistentDomain(
      forName: UserDefaults.globalDomain
    )?[feedbackPreferenceKey]
  }

  private static func loadVolumeFeedbackSound() -> NSSound? {
    VolumeFeedbackAssetSelection.firstLoadable(
      paths: soundAssetPaths
    ) { path in
      guard FileManager.default.isReadableFile(atPath: path) else {
        return nil
      }
      return NSSound(
        contentsOfFile: path,
        byReference: false
      )
    }
  }

  private static let feedbackPreferenceKey =
    "com.apple.sound.beep.feedback"
  private static let soundAssetPaths = [
    "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
    "/System/Library/PrivateFrameworks/BezelServices.framework/Versions/A/Resources/volume.aiff",
    "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Media Keys.aif",
  ]
}
