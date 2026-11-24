// User preferences, with the defaults most people want. Everything here can be
// changed from the Settings submenu.
//
// SPDX-License-Identifier: MIT

import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// The Sound slider and volume keys also drive the monitor's own speakers
    /// above `VolumeCurve.softwareShare`, and keep them at a safe base level below.
    static var oneVolumeControl: Bool {
        get { defaults.object(forKey: "oneVolumeControl") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "oneVolumeControl") }
    }

    /// Fade displays to their night brightness at night and back in the morning.
    static var nightDimming: Bool {
        get { defaults.object(forKey: "nightDimming") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "nightDimming") }
    }

    static var nightSchedule: NightSchedule {
        get { defaults.string(forKey: "nightSchedule").flatMap(NightSchedule.init(storageValue:)) ?? .sun }
        set { defaults.set(newValue.storageValue, forKey: "nightSchedule") }
    }
}

extension DDCDisplay {
    /// The monitor's speaker level while Hush handles volume in software, and
    /// whenever Hush isn't running: loud enough to hear, quiet enough to be safe.
    /// Snapped to a step the monitor has, so reading it back compares equal.
    var speakerBase: Float {
        get { quantized(.speakerVolume, UserDefaults.standard.object(forKey: key + ".speakerBase") as? Float ?? 0.25) }
        set { UserDefaults.standard.set(newValue, forKey: key + ".speakerBase") }
    }

    /// Brightness level (Hush's combined scale) remembered for day or night.
    func savedLevel(night: Bool) -> Float? {
        UserDefaults.standard.object(forKey: levelKey(night: night)) as? Float
    }

    func saveLevel(_ level: Float, night: Bool) {
        UserDefaults.standard.set(level, forKey: levelKey(night: night))
    }

    private func levelKey(night: Bool) -> String {
        key + (night ? ".nightLevel" : ".dayLevel")
    }
}
