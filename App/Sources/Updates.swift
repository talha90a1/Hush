// Software updates through Sparkle, from the appcast published with each GitHub release.
//
// SPDX-License-Identifier: MIT

import AppKit
import Sparkle

final class Updates: NSObject, SPUStandardUserDriverDelegate {
    private(set) lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    /// Hush lives in the menu bar, so scheduled update alerts would open behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
