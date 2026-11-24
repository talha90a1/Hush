// Control Center–style slider, as in the Sound and Display modules of macOS 27:
// a small SF Symbol at each end and a thin rounded track with a white fill.
//
// SPDX-License-Identifier: MIT

import AppKit

final class ModuleSlider: NSView {
    enum Style {
        case volume, brightness, contrast, speaker

        func leadingSymbol(muted: Bool) -> String {
            switch self {
            case .volume: return muted ? "speaker.slash.fill" : "speaker.fill"
            case .brightness: return "sun.min"
            case .contrast: return "circle.lefthalf.filled"
            case .speaker: return "speaker"
            }
        }

        var trailingSymbol: String {
            switch self {
            case .volume: return "speaker.wave.3.fill"
            case .brightness: return "sun.max"
            case .contrast: return "circle.righthalf.filled"
            case .speaker: return "speaker.wave.3"
            }
        }

        /// What VoiceOver calls the slider.
        var label: String {
            switch self {
            case .volume: return "Volume"
            case .brightness: return "Brightness"
            case .contrast: return "Contrast"
            case .speaker: return "Monitor speakers"
            }
        }
    }

    static let height: CGFloat = 24
    private static let iconBox: CGFloat = 22
    private static let gap: CGFloat = 8
    private static let trackHeight: CGFloat = 5

    var style: Style { didSet { needsDisplay = true } }
    /// 0…1.
    var value: Float = 0 { didSet { if value != oldValue { needsDisplay = true } } }
    /// Draws the empty (muted) state while keeping `value`.
    var muted = false { didSet { if muted != oldValue { needsDisplay = true } } }
    /// Called for changes the user makes, not for `value` set in code.
    var onChange: ((Float) -> Void)?
    var isInteractive = true

    init(style: Style, width: CGFloat) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackRect: NSRect {
        let inset = Self.iconBox + Self.gap
        return NSRect(x: inset, y: (bounds.height - Self.trackHeight) / 2,
                      width: bounds.width - inset * 2, height: Self.trackHeight)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = track.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let shown = muted ? 0 : CGFloat(max(0, min(1, value)))
        if shown > 0 {
            var filled = track
            filled.size.width = max(track.height, track.width * shown)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }

        drawSymbol(style.leadingSymbol(muted: muted || value == 0), centeredAt: Self.iconBox / 2)
        drawSymbol(style.trailingSymbol, centeredAt: bounds.width - Self.iconBox / 2)
    }

    private func drawSymbol(_ name: String, centeredAt x: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [.labelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = NSRect(x: x - size.width / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        guard isInteractive else { return }
        let track = trackRect
        let x = convert(event.locationInWindow, from: nil).x
        set(Float(max(0, min(1, (x - track.minX) / track.width))))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        let delta = Float(event.scrollingDeltaY - event.scrollingDeltaX) / (event.hasPreciseScrollingDeltas ? 300 : 30)
        set(max(0, min(1, value + delta)))
    }

    private func set(_ newValue: Float) {
        value = newValue
        muted = false
        onChange?(newValue)
    }

    // MARK: Accessibility

    // Custom-drawn, so VoiceOver needs the role and value spelled out. The HUD's
    // slider is display-only and stays hidden from it.
    override func isAccessibilityElement() -> Bool { isInteractive }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { style.label }
    override func accessibilityValue() -> Any? { NSNumber(value: muted ? 0 : value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
    override func accessibilityValueDescription() -> String? {
        muted ? "Muted" : "\(Int((value * 100).rounded())) percent"
    }

    override func accessibilityPerformIncrement() -> Bool { nudge(1) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1) }

    private func nudge(_ direction: Float) -> Bool {
        guard isInteractive else { return false }
        set(max(0, min(1, value + direction / 16)))
        return true
    }
}
