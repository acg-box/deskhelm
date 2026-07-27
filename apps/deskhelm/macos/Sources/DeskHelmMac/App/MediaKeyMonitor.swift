import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import DeskHelmAppCore
import OSLog

@MainActor
final class MediaKeyMonitor {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "MediaKeys"
  )
  private let onEvent: (VolumeMediaKeyEvent, String?) -> Void
  private let onDisabled: (String) -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(
    onEvent: @escaping (VolumeMediaKeyEvent, String?) -> Void,
    onDisabled: @escaping (String) -> Void
  ) {
    self.onEvent = onEvent
    self.onDisabled = onDisabled
  }

  var isRunning: Bool {
    guard let eventTap else { return false }
    return CGEvent.tapIsEnabled(tap: eventTap)
  }

  static var hasAccessibilityAccess: Bool {
    AXIsProcessTrusted()
  }

  func start() throws {
    guard eventTap == nil else { return }
    guard Self.hasAccessibilityAccess else {
      throw MediaKeyMonitorError.permissionRequired
    }

    let eventMask =
      CGEventMask(1)
      << UInt64(NSEvent.EventType.systemDefined.rawValue)
    let userInfo = Unmanaged.passUnretained(self).toOpaque()

    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: deskHelmMediaKeyCallback,
        userInfo: userInfo
      )
    else {
      throw MediaKeyMonitorError.tapCreationFailed
    }

    guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
    else {
      CFMachPortInvalidate(eventTap)
      throw MediaKeyMonitorError.runLoopSourceFailed
    }

    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      runLoopSource,
      .commonModes
    )
    self.eventTap = eventTap
    self.runLoopSource = runLoopSource
    CGEvent.tapEnable(tap: eventTap, enable: true)
    publishState("running")
  }

  func stop() {
    if let runLoopSource {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        runLoopSource,
        .commonModes
      )
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }

    runLoopSource = nil
    eventTap = nil
    publishState("stopped")
  }

  fileprivate func receive(
    _ event: VolumeMediaKeyEvent,
    targetDeviceUID: String?
  ) {
    logger.debug(
      "Observed volume event: \(String(describing: event), privacy: .public), target=\(targetDeviceUID != nil, privacy: .public)"
    )
    onEvent(event, targetDeviceUID)
  }

  fileprivate func handleTapDisabled() {
    stop()
    onDisabled(
      "macOS disabled keyboard volume control. DeskHelm will retry safely."
    )
  }

  private func publishState(_ state: String) {
    let defaults = UserDefaults.standard

    defaults.set(
      ProcessInfo.processInfo.processIdentifier,
      forKey: "MediaKeyMonitorPID"
    )
    defaults.set(state, forKey: "MediaKeyMonitorState")
    defaults.synchronize()
    logger.notice("media-key-monitor \(state, privacy: .public)")
  }
}

private func deskHelmMediaKeyCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }

  let monitor =
    Unmanaged<MediaKeyMonitor>
    .fromOpaque(userInfo)
    .takeUnretainedValue()

  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    Task { @MainActor in
      monitor.handleTapDisabled()
    }
    return Unmanaged.passUnretained(event)
  }

  guard
    type.rawValue == NSEvent.EventType.systemDefined.rawValue,
    let appKitEvent = NSEvent(cgEvent: event),
    let mediaKeyEvent = VolumeMediaKeyDecoder.decode(
      subtype: appKitEvent.subtype.rawValue,
      data1: appKitEvent.data1,
      shouldInvertFeedback:
        VolumeFeedbackModifierPolicy.shouldInvertSystemPreference(
          for: appKitEvent.modifierFlags
        )
    )
  else {
    return Unmanaged.passUnretained(event)
  }

  let targetDeviceUID = DefaultAudioOutputRoute.currentTargetDeviceUID
  let disposition = VolumeMediaKeyRoutingPolicy.disposition(
    for: mediaKeyEvent,
    outputMatchesTarget: targetDeviceUID != nil
  )

  switch disposition {
  case .passThrough:
    return Unmanaged.passUnretained(event)
  case .passThroughAndDispatch(let observedEvent):
    deliver(
      observedEvent,
      targetDeviceUID: nil,
      to: monitor
    )
    return Unmanaged.passUnretained(event)
  case .consumeAndDispatch(let observedEvent):
    deliver(
      observedEvent,
      targetDeviceUID: targetDeviceUID,
      to: monitor
    )
    return nil
  }
}

enum VolumeFeedbackModifierPolicy {
  static func shouldInvertSystemPreference(
    for modifiers: NSEvent.ModifierFlags
  ) -> Bool {
    modifiers.contains(.shift)
      && !modifiers.contains(.control)
      && !modifiers.contains(.option)
      && !modifiers.contains(.command)
  }
}

private func deliver(
  _ event: VolumeMediaKeyEvent,
  targetDeviceUID: String?,
  to monitor: MediaKeyMonitor
) {
  if Thread.isMainThread {
    MainActor.assumeIsolated {
      monitor.receive(event, targetDeviceUID: targetDeviceUID)
    }
    return
  }

  Task { @MainActor in
    monitor.receive(event, targetDeviceUID: targetDeviceUID)
  }
}

private enum MediaKeyMonitorError: LocalizedError {
  case permissionRequired
  case tapCreationFailed
  case runLoopSourceFailed

  var errorDescription: String? {
    switch self {
    case .permissionRequired:
      "Keyboard volume control needs Accessibility permission."
    case .tapCreationFailed:
      "macOS did not create the volume-key event filter."
    case .runLoopSourceFailed:
      "DeskHelm could not attach the volume-key event filter to its run loop."
    }
  }
}
