package enum DeskHelmLaunchAction: Equatable, Sendable {
  case restoreRequestedVolumeKeys
  case showSettingsForVerification
}

package enum DeskHelmLaunchPlan {
  package static func actions(
    arguments: [String]
  ) -> [DeskHelmLaunchAction] {
    var actions: [DeskHelmLaunchAction] = [
      .restoreRequestedVolumeKeys
    ]

    if arguments.contains("--verify-settings") {
      actions.append(.showSettingsForVerification)
    }

    return actions
  }
}
