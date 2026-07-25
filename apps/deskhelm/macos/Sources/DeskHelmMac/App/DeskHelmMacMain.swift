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
  private var settingsWindowController: SettingsWindowController?
  private var volumeKeyController: VolumeKeyController?
  private var softwareUpdater: SoftwareUpdater?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let launchActions = DeskHelmLaunchPlan.actions(
        arguments: CommandLine.arguments
      )
      let store = VolumeStore(controller: DeskHelmCore())
      let volumeKeyState = VolumeKeyFeatureState()
      let accessibilityPermission = AccessibilityPermission()
      let volumeKeyController = VolumeKeyController(
        store: store,
        state: volumeKeyState,
        accessibilityPermission: accessibilityPermission
      )
      let launchAtLogin = LaunchAtLoginController()
      let softwareUpdater = SoftwareUpdater()
      let settingsWindowController = SettingsWindowController(
        store: store,
        volumeKeyState: volumeKeyState,
        volumeKeyController: volumeKeyController,
        accessibilityPermission: accessibilityPermission,
        launchAtLogin: launchAtLogin,
        softwareUpdater: softwareUpdater
      )
      volumeKeyController.setHUDPresentationPolicy {
        [weak settingsWindowController] in
        settingsWindowController?.isPresentingSettings != true
      }
      softwareUpdater.onPresentationFinished {
        [weak settingsWindowController] in
        settingsWindowController?.externalWindowPresentationDidFinish()
      }

      self.volumeKeyController = volumeKeyController
      self.softwareUpdater = softwareUpdater
      self.settingsWindowController = settingsWindowController
      configureMainMenu()

      let statusItemController = try StatusItemController(
        updateTitle: softwareUpdater.snapshot().isConfigured
          ? "Check for Updates…"
          : "View Releases…",
        onShowSettings: { [weak self] in
          self?.showSettings(nil)
        },
        onCheckForUpdates: { [weak self] in
          self?.checkForUpdates(nil)
        },
        onQuit: {
          NSApp.terminate(nil)
        }
      )
      self.statusItemController = statusItemController
      publishReadyState(for: statusItemController)

      for action in launchActions {
        switch action {
        case .restoreRequestedVolumeKeys:
          volumeKeyController.restoreIfRequested()
        case .showSettingsForVerification:
          Task { @MainActor [weak self] in
            await Task.yield()
            self?.showSettings(nil)
          }
        }
      }
    } catch {
      logger.fault(
        "DeskHelm could not create its status menu: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    volumeKeyController?.invalidate()
    volumeKeyController = nil
    settingsWindowController?.closeForTermination()
    settingsWindowController = nil
    statusItemController?.invalidate()
    statusItemController = nil
    softwareUpdater = nil
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  @objc
  private func showSettings(_ sender: Any?) {
    settingsWindowController?.present()
  }

  @objc
  private func checkForUpdates(_ sender: Any?) {
    guard let softwareUpdater else { return }

    if !softwareUpdater.snapshot().isConfigured {
      softwareUpdater.checkForUpdates(sender)
      return
    }

    settingsWindowController?.present()
    softwareUpdater.checkForUpdates(sender)
  }

  @objc
  private func quit(_ sender: Any?) {
    NSApp.terminate(sender)
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()
    let applicationMenuItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "DeskHelm")

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showSettings(_:)),
      keyEquivalent: ","
    )
    settingsItem.keyEquivalentModifierMask = [.command]
    settingsItem.target = self
    applicationMenu.addItem(settingsItem)

    let updateTitle =
      softwareUpdater?.snapshot().isConfigured == true
      ? "Check for Updates…"
      : "View Releases…"
    let updateItem = NSMenuItem(
      title: updateTitle,
      action: #selector(checkForUpdates(_:)),
      keyEquivalent: ""
    )
    updateItem.target = self
    applicationMenu.addItem(updateItem)

    applicationMenu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit DeskHelm",
      action: #selector(quit(_:)),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = self
    applicationMenu.addItem(quitItem)

    applicationMenuItem.submenu = applicationMenu
    mainMenu.addItem(applicationMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    let closeItem = NSMenuItem(
      title: "Close",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    closeItem.keyEquivalentModifierMask = [.command]
    windowMenu.addItem(closeItem)
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenu
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
