import AppKit
import DeskHelmAppCore
import OSLog

@main
@MainActor
struct DeskHelmMacMain {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "Application"
  )
  private var statusItemController: StatusItemController?
  private var volumeKeyController: VolumeKeyController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let store = VolumeStore(controller: DeskHelmCore())
      let volumeKeyState = VolumeKeyFeatureState()
      let volumeKeyController = VolumeKeyController(
        store: store,
        state: volumeKeyState
      )
      let controller = try StatusItemController(
        store: store,
        volumeKeyState: volumeKeyState,
        onToggleVolumeKeys: {
          volumeKeyController.toggle()
        }
      )
      self.volumeKeyController = volumeKeyController
      statusItemController = controller
      publishReadyState(for: controller)
      if !CommandLine.arguments.contains("--verify-panel") {
        volumeKeyController.restoreIfRequested()
      }

      if CommandLine.arguments.contains("--verify-panel") {
        Task { @MainActor in
          await Task.yield()
          controller.showPanelForVerification()
        }
      }
    } catch {
      logger.fault(
        "DeskHelm could not create its status item: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    volumeKeyController?.invalidate()
    volumeKeyController = nil
    statusItemController?.invalidate()
    statusItemController = nil
  }

  private func publishReadyState(for controller: StatusItemController) {
    let processIdentifier = ProcessInfo.processInfo.processIdentifier
    let defaults = UserDefaults.standard

    defaults.set(processIdentifier, forKey: "StatusItemReadyPID")
    defaults.set(controller.diagnosticSummary, forKey: "StatusItemReadySummary")
    defaults.synchronize()

    logger.notice(
      "status-item-ready pid=\(processIdentifier) \(controller.diagnosticSummary, privacy: .public)"
    )
  }
}
