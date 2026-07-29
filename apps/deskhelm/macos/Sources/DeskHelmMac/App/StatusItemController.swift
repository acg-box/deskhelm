import AppKit
import OSLog

@MainActor
final class StatusItemController {
  private let logger = Logger(
    subsystem: "com.acgbox.deskhelm",
    category: "StatusItem"
  )
  private let statusItem: NSStatusItem
  private let menu = NSMenu(title: "DeskHelm")
  private let onShowSettings: () -> Void
  private let onCheckForUpdates: () -> Void
  private let onQuit: () -> Void

  var diagnosticSummary: String {
    let button = statusItem.button
    let isAccessoryApplication = NSApp.activationPolicy() == .accessory
    return
      "button=\(button != nil) image=\(button?.image != nil) "
      + "visible=\(statusItem.isVisible) window=\(button?.window?.isVisible == true) "
      + "titleEmpty=\(button?.title.isEmpty == true) menu=true panel=false "
      + "accessory=\(isAccessoryApplication)"
  }

  init(
    updateTitle: String,
    onShowSettings: @escaping () -> Void,
    onCheckForUpdates: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) throws {
    self.onShowSettings = onShowSettings
    self.onCheckForUpdates = onCheckForUpdates
    self.onQuit = onQuit
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )

    guard let button = statusItem.button else {
      NSStatusBar.system.removeStatusItem(statusItem)
      throw StatusItemError.buttonUnavailable
    }

    guard let statusIcon = DeskHelmStatusIcon.makeImage() else {
      NSStatusBar.system.removeStatusItem(statusItem)
      throw StatusItemError.iconUnavailable
    }

    configureStatusButton(button, image: statusIcon)
    configureMenu(updateTitle: updateTitle)
    statusItem.menu = menu
    statusItem.isVisible = true

    logger.notice(
      "Created native status menu: \(self.diagnosticSummary, privacy: .public)"
    )
  }

  func invalidate() {
    statusItem.menu = nil
    menu.removeAllItems()
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  private func configureStatusButton(
    _ button: NSStatusBarButton,
    image: NSImage
  ) {
    button.image = image
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.title = ""
    button.toolTip = "DeskHelm"
    button.setAccessibilityLabel("DeskHelm menu")
  }

  private func configureMenu(updateTitle: String) {
    menu.autoenablesItems = false

    let updateItem = NSMenuItem(
      title: updateTitle,
      action: #selector(checkForUpdates(_:)),
      keyEquivalent: ""
    )
    updateItem.target = self
    updateItem.isEnabled = true
    menu.addItem(updateItem)

    menu.addItem(.separator())

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showSettings(_:)),
      keyEquivalent: ","
    )
    settingsItem.keyEquivalentModifierMask = [.command]
    settingsItem.target = self
    settingsItem.isEnabled = true
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(quit(_:)),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = self
    quitItem.isEnabled = true
    menu.addItem(quitItem)
  }

  @objc
  private func showSettings(_ sender: Any?) {
    onShowSettings()
  }

  @objc
  private func checkForUpdates(_ sender: Any?) {
    onCheckForUpdates()
  }

  @objc
  private func quit(_ sender: Any?) {
    onQuit()
  }
}

private enum StatusItemError: LocalizedError {
  case buttonUnavailable
  case iconUnavailable

  var errorDescription: String? {
    switch self {
    case .buttonUnavailable:
      "macOS did not provide a button for the DeskHelm status item."
    case .iconUnavailable:
      "macOS does not provide the control-deck symbol used by DeskHelm."
    }
  }
}
