// On-screen volume and brightness indicator.
//
// macOS 26 and later no longer draw the private OSDManager bezel for third-party
// apps, so Hush draws its own: a click-through, non-activating panel styled like
// the system HUD (blurred material, SF Symbol, level bar) that fades out on its own.
//
// SPDX-License-Identifier: MIT

import AppKit

/// Main thread only, like the rest of the UI.
final class HUD {
    enum Kind {
        case volume, mute, brightness

        func symbol(level: Float) -> String {
            switch self {
            case .brightness: return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
            case .mute: return "speaker.slash.fill"
            case .volume:
                switch level {
                case 0: return "speaker.slash.fill"
                case ..<0.34: return "speaker.wave.1.fill"
                case ..<0.67: return "speaker.wave.2.fill"
                default: return "speaker.wave.3.fill"
                }
            }
        }
    }

    static let shared = HUD()

    private static let size = NSSize(width: 300, height: 52)
    private static let visibleFor: TimeInterval = 1.5

    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.size.height / 2
        background.layer?.masksToBounds = true

        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone

        let stack = NSStackView(views: [icon, bar])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 22)
        stack.frame = background.bounds
        stack.autoresizingMask = [.width, .height]
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        background.addSubview(stack)
        panel.contentView = background
    }

    /// Shows `level` (0…1) for `kind` near the top of the given display.
    func show(_ kind: Kind, level: Float, on displayID: CGDirectDisplayID) {
        let shown = kind == .mute ? 0 : max(0, min(1, level))
        icon.image = NSImage(systemSymbolName: kind.symbol(level: shown), accessibilityDescription: nil)
        bar.level = CGFloat(shown)

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 12))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
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

/// Rounded track with a filled portion, like the system HUD's level bar.
private final class LevelBar: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard level > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * level)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
