// Night dimming: fades each display to its night brightness when night starts
// and back to its day brightness in the morning. The levels are learned: a
// brightness you set at night becomes the night level, by day the day level.
//
// SPDX-License-Identifier: MIT

import CoreLocation
import Foundation

/// Main thread only.
final class NightMode {
    private static let checkEvery: TimeInterval = 60
    private static let fadeSteps = 40
    private static let fadeStep: TimeInterval = 1.5 // 1 minute in all
    /// Smallest change worth a fade: about one step of a monitor's backlight.
    /// A level read back from the monitor differs from the saved one by less.
    private static let tolerance: Float = 0.01

    /// Displays to manage, their current level, and how to apply a level.
    var displays: () -> [DDCDisplay] = { [] }
    var level: (DDCDisplay) -> Float = { _ in 0 }
    var apply: (Float, DDCDisplay) -> Void = { _, _ in }

    /// Where the Mac is, looked up again when its time zone changes (travel).
    private var zone = ""
    private var coordinate: CLLocationCoordinate2D?
    private var timer: Timer?
    private var fade: Timer?
    /// Night or day as of the last check; nil before the first one or while off.
    private(set) var isNight: Bool?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    /// Settings, displays or the clock changed (wake): fade if day/night changed.
    func check() {
        guard Settings.nightDimming else {
            isNight = nil
            stopFade()
            return
        }
        let timeZone = TimeZone.autoupdatingCurrent
        if timeZone.identifier != zone {
            zone = timeZone.identifier
            coordinate = TimeZoneLocation.location(of: zone)
        }
        let night = Settings.nightSchedule.isNight(at: Date(), timeZone: timeZone, coordinate: coordinate)
        guard night != isNight else { return }
        isNight = night
        fade(toNight: night)
    }

    /// Start over after a settings change, so the new schedule applies right away.
    func reset() {
        isNight = nil
        check()
    }

    /// The user set a brightness: remember it for the current part of the day.
    func userSetLevel(_ level: Float, of display: DDCDisplay) {
        stopFade()
        guard let isNight else { return }
        display.saveLevel(level, night: isNight)
    }

    private func fade(toNight night: Bool) {
        stopFade()
        let plans: [(display: DDCDisplay, from: Float, to: Float)] = displays().map { display in
            let current = level(display)
            let plan = NightLevels.plan(night: night, current: current, savedDay: display.savedLevel(night: false),
                                        savedNight: display.savedLevel(night: true))
            if let day = plan.learnDay { display.saveLevel(day, night: false) }
            return (display, current, plan.target)
        }.filter { abs($0.from - $0.to) > Self.tolerance }
        guard !plans.isEmpty else { return }

        var step = 0
        fade = Timer.scheduledTimer(withTimeInterval: Self.fadeStep, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let progress = Float(step) / Float(Self.fadeSteps)
            for plan in plans { self.apply(plan.from + (plan.to - plan.from) * progress, plan.display) }
            if step >= Self.fadeSteps { self.stopFade() }
        }
    }

    private func stopFade() {
        fade?.invalidate()
        fade = nil
    }
}
