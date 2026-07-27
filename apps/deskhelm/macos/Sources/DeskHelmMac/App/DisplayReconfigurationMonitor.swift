import CoreGraphics
import Foundation
import OSLog

enum DisplayReconfigurationEvent: Equatable, Sendable {
  case began
  case settled
}

@MainActor
protocol DisplayReconfigurationMonitoring: AnyObject {
  func start() throws
  func stop()
}

@MainActor
final class DisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
  typealias EventHandler = @MainActor (DisplayReconfigurationEvent) -> Void

  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "DisplayReconfiguration"
  )
  private let settleDelay: Duration
  private let onEvent: EventHandler
  private var isRegistered = false
  private var isConfigurationInProgress = false
  private var settleTask: Task<Void, Never>?
  private var callbackContext: DisplayReconfigurationCallbackContext?

  init(
    settleDelay: Duration = .milliseconds(500),
    onEvent: @escaping EventHandler
  ) {
    self.settleDelay = settleDelay
    self.onEvent = onEvent
  }

  func start() throws {
    if isRegistered {
      callbackContext?.activate()
      return
    }

    let context = DisplayReconfigurationCallbackContext {
      [weak self] flags in
      self?.receive(flags)
    }

    let status = CGDisplayRegisterReconfigurationCallback(
      deskHelmDisplayReconfigurationCallback,
      Unmanaged.passUnretained(context).toOpaque()
    )
    guard status == .success else {
      context.deactivate()
      throw DisplayReconfigurationMonitorError.registrationFailed(status)
    }

    DisplayReconfigurationContextQuarantine.shared.retain(context)
    callbackContext = context
    isRegistered = true
    logger.notice("display-reconfiguration-monitor running")
  }

  func stop() {
    settleTask?.cancel()
    settleTask = nil
    isConfigurationInProgress = false
    callbackContext?.deactivate()

    guard isRegistered, let callbackContext else { return }

    let status = CGDisplayRemoveReconfigurationCallback(
      deskHelmDisplayReconfigurationCallback,
      Unmanaged.passUnretained(callbackContext).toOpaque()
    )
    if status != .success {
      logger.error(
        "Could not remove display-reconfiguration callback: \(status.rawValue, privacy: .public)"
      )
      return
    }

    isRegistered = false
    self.callbackContext = nil
    logger.notice("display-reconfiguration-monitor stopped")
  }

  func receive(_ flags: CGDisplayChangeSummaryFlags) {
    if flags.rawValue & Self.beginConfigurationFlag != 0 {
      beginConfigurationIfNeeded()
      return
    }

    beginConfigurationIfNeeded()
    settleTask?.cancel()
    settleTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: settleDelay)
      } catch {
        return
      }
      guard !Task.isCancelled, isConfigurationInProgress else { return }

      isConfigurationInProgress = false
      settleTask = nil
      logger.notice("display-reconfiguration settled")
      onEvent(.settled)
    }
  }

  private func beginConfigurationIfNeeded() {
    settleTask?.cancel()
    settleTask = nil
    guard !isConfigurationInProgress else { return }

    isConfigurationInProgress = true
    logger.notice("display-reconfiguration began")
    onEvent(.began)
  }

  // CoreGraphics exposes kCGDisplayBeginConfigurationFlag as bit zero in C.
  // The current Swift overlay does not provide a named member for that flag.
  private static let beginConfigurationFlag: UInt32 = 1 << 0
}

private func deskHelmDisplayReconfigurationCallback(
  _: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ userInfo: UnsafeMutableRawPointer?
) {
  guard let userInfo else { return }

  let context =
    Unmanaged<DisplayReconfigurationCallbackContext>
    .fromOpaque(userInfo)
    .takeUnretainedValue()

  context.enqueue(flags)
}

final class DisplayReconfigurationCallbackContext: @unchecked Sendable {
  typealias Handler = @MainActor (CGDisplayChangeSummaryFlags) -> Void

  private let lock = NSLock()
  private let handler: Handler
  private var isActive = true
  private var pendingRawFlags: [UInt32] = []
  private var isDrainScheduled = false

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func activate() {
    lock.withLock {
      isActive = true
    }
  }

  func deactivate() {
    lock.withLock {
      isActive = false
      pendingRawFlags.removeAll()
    }
  }

  func enqueue(_ flags: CGDisplayChangeSummaryFlags) {
    let shouldSchedule = lock.withLock {
      guard isActive else { return false }

      pendingRawFlags.append(flags.rawValue)
      guard !isDrainScheduled else { return false }

      isDrainScheduled = true
      return true
    }
    guard shouldSchedule else { return }

    Task { @MainActor [self] in
      drain()
    }
  }

  @MainActor
  private func drain() {
    while let rawFlags = takePendingRawFlags() {
      for rawValue in rawFlags {
        handler(CGDisplayChangeSummaryFlags(rawValue: rawValue))
      }
    }
  }

  private func takePendingRawFlags() -> [UInt32]? {
    lock.withLock {
      guard isActive, !pendingRawFlags.isEmpty else {
        isDrainScheduled = false
        return nil
      }

      let rawFlags = pendingRawFlags
      pendingRawFlags.removeAll(keepingCapacity: true)
      return rawFlags
    }
  }
}

private final class DisplayReconfigurationContextQuarantine:
  @unchecked Sendable
{
  static let shared = DisplayReconfigurationContextQuarantine()

  private let lock = NSLock()
  private var contexts: [DisplayReconfigurationCallbackContext] = []

  func retain(_ context: DisplayReconfigurationCallbackContext) {
    lock.withLock {
      contexts.append(context)
    }
  }
}

private enum DisplayReconfigurationMonitorError: LocalizedError {
  case registrationFailed(CGError)

  var errorDescription: String? {
    switch self {
    case .registrationFailed(let status):
      "DeskHelm could not observe display connection changes "
        + "(CoreGraphics error \(status.rawValue))."
    }
  }
}
