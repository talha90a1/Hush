// Dims a display below its lowest hardware brightness with a black,
// click-through overlay. Capped so the screen never goes fully black.
//
// SPDX-License-Identifier: MIT

import AppKit

/// Main thread only, like the rest of the UI.
final class Dimmer {
    static let shared = Dimmer()

    /// Darkest the overlay gets, so you can always see enough to undo it.
    private static let maxOpacity: CGFloat = 0.8

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var depths: [CGDirectDisplayID: Float] = [:]

    /// 0 (off) … 1 (darkest) for that display.
    func depth(of displayID: CGDirectDisplayID) -> Float { depths[displayID] ?? 0 }

    func setDepth(_ depth: Float, for displayID: CGDirectDisplayID) {
        let depth = max(0, min(1, depth))
        depths[displayID] = depth
        guard depth > 0, let screen = Self.screen(displayID) else {
            windows.removeValue(forKey: displayID)?.orderOut(nil)
            return
        }
        let window = windows[displayID] ?? makeWindow()
        windows[displayID] = window
        window.setFrame(screen.frame, display: false)
        window.alphaValue = CGFloat(depth) * Self.maxOpacity
        window.orderFrontRegardless()
    }

    /// Drops the overlay of every display not in `displayIDs`: without DDC there
    /// is no brightness control left to undo it with.
    func keep(only displayIDs: Set<CGDirectDisplayID>) {
        for displayID in depths.keys where !displayIDs.contains(displayID) {
            depths[displayID] = nil
            windows.removeValue(forKey: displayID)?.orderOut(nil)
        }
    }

    /// Screens moved or changed: put each overlay back over its display, drop the rest.
    func refresh() {
        for (displayID, depth) in depths { setDepth(depth, for: displayID) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return window
    }

    private static func screen(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
