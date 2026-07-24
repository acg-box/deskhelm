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
  private let onAction: (VolumeMediaKeyAction) -> Void
  private let onDisabled: (String) -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(
    onAction: @escaping (VolumeMediaKeyAction) -> Void,
    onDisabled: @escaping (String) -> Void
  ) {
    self.onAction = onAction
    self.onDisabled = onDisabled
  }

  var isRunning: Bool {
    guard let eventTap else { return false }
    return CGEvent.tapIsEnabled(tap: eventTap)
  }

  static var hasAccessibilityAccess: Bool {
    AXIsProcessTrusted()
  }

  static func requestAccessibilityAccess() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
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

  fileprivate func receive(_ action: VolumeMediaKeyAction) {
    logger.debug(
      "Received allowlisted volume action: \(String(describing: action), privacy: .public)"
    )
    onAction(action)
  }

  fileprivate func handleTapDisabled() {
    stop()
    onDisabled(
      "macOS disabled keyboard volume control. Enable it again from the DeskHelm menu."
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
      data1: appKitEvent.data1
    )
  else {
    return Unmanaged.passUnretained(event)
  }

  let disposition = VolumeMediaKeyRoutingPolicy.disposition(
    for: mediaKeyEvent,
    outputMatchesTarget: DefaultAudioOutputRoute.shouldInterceptVolumeKeys
  )

  guard disposition != .passThrough else {
    return Unmanaged.passUnretained(event)
  }

  if case .consumeAndDispatch(let action) = disposition {
    Task { @MainActor in
      monitor.receive(action)
    }
  }

  return nil
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
