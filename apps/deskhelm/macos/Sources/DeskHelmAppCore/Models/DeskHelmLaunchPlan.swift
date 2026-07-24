package enum DeskHelmLaunchAction: Equatable, Sendable {
  case restoreRequestedVolumeKeys
  case showPanelForVerification
}

package enum DeskHelmLaunchPlan {
  package static func actions(
    arguments: [String]
  ) -> [DeskHelmLaunchAction] {
    var actions: [DeskHelmLaunchAction] = [
      .restoreRequestedVolumeKeys
    ]

    if arguments.contains("--verify-panel") {
      actions.append(.showPanelForVerification)
    }

    return actions
  }
}
