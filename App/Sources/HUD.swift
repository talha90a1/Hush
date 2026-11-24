// On-screen volume and brightness indicator.
//
// macOS 26 and later no longer draw the private OSDManager bezel for third-party
// apps, so Hush draws its own in the current system style: a Liquid Glass pill
// near the top-right corner holding a Control Center–style slider. Click-through,
// never takes focus, fades out on its own.
//
// SPDX-License-Identifier: MIT

import AppKit

/// Main thread only, like the rest of the UI.
final class HUD {
    enum Kind { case volume, mute, brightness }

    static let shared = HUD()

    private static let size = NSSize(width: 260, height: 48)
    private static let margin: CGFloat = 10
    private static let visibleFor: TimeInterval = 1.5

    private let panel: NSPanel
    private let slider = ModuleSlider(style: .volume, width: size.width - 28)
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver // above the dimming overlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        slider.isInteractive = false
        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        slider.frame.origin = NSPoint(x: 14, y: (Self.size.height - ModuleSlider.height) / 2)
        content.addSubview(slider)
        panel.contentView = Self.glass(around: content, cornerRadius: Self.size.height / 2)
    }

    /// Shows `level` (0…1) for `kind` at the top-right of the given display.
    func show(_ kind: Kind, level: Float, on displayID: CGDirectDisplayID) {
        slider.style = kind == .brightness ? .brightness : .volume
        slider.value = max(0, min(1, level))
        slider.muted = kind == .mute

        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - Self.margin,
                                         y: frame.maxY - Self.size.height - Self.margin))
        }

        // Through the animator, so a fade-out still running is replaced, not left to finish.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    /// Liquid Glass on macOS 26 and later, the blurred HUD material before that.
    private static func glass(around content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView(frame: content.frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.addSubview(content)
        return blur
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }
}
