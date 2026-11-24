// One volume scale over two controls: Hush's software volume and the monitor's
// own speaker volume (DDC). The lower part of the scale is software only, with
// the monitor held at a safe base level; the top part raises the monitor.
//
// SPDX-License-Identifier: MIT

import Foundation

enum VolumeCurve {
    /// Share of the scale that is software volume over the monitor's base level.
    static let softwareShare: Float = 0.75

    struct Split: Equatable {
        /// Hush's own volume, 0…1.
        let software: Float
        /// The monitor's speaker volume, 0…1 of its range.
        let hardware: Float
    }

    static func split(_ level: Float, base: Float) -> Split {
        let level = clamp(level), base = clamp(base)
        guard level > softwareShare, base < 1 else {
            return Split(software: min(1, level / softwareShare), hardware: base)
        }
        return Split(software: 1, hardware: base + (1 - base) * (level - softwareShare) / (1 - softwareShare))
    }

    /// The monitor's part counts only while Hush's own volume is full. Something
    /// else can lower that volume (Control Center, macOS's own volume keys), and
    /// reading the result as "above 75%" would make the next step put the software
    /// volume back to full: suddenly loud. `base` must be a value the monitor can
    /// hold (see `DDCDisplay.speakerBase`), or rounding would look like a raise.
    static func level(software: Float, hardware: Float, base: Float) -> Float {
        let base = clamp(base), software = clamp(software)
        if software >= 0.999, base < 1, hardware > base + 0.001 {
            return softwareShare + (1 - softwareShare) * min(1, (hardware - base) / (1 - base))
        }
        return softwareShare * software
    }

    private static func clamp(_ value: Float) -> Float { max(0, min(1, value)) }
}
