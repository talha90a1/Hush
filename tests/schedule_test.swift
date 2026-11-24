// Checks the one-volume curve and the night schedule.
//
//   mkdir -p build && swiftc -parse-as-library App/Sources/VolumeCurve.swift App/Sources/NightSchedule.swift App/Sources/Solar.swift tests/schedule_test.swift -o build/schedule_test && build/schedule_test
//
// SPDX-License-Identifier: MIT

import CoreLocation
import Foundation

@main
enum ScheduleTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }

    static func main() {
        volumeCurve()
        zoneTable()
        schedule()
        nightLevels()
        print(failures == 0 ? "PASS" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func volumeCurve() {
        let base: Float = 0.25
        check(VolumeCurve.split(0, base: base) == .init(software: 0, hardware: base), "silent")
        check(close(VolumeCurve.split(0.375, base: base).software, 0.5), "half of the software part")
        check(VolumeCurve.split(0.75, base: base) == .init(software: 1, hardware: base), "top of the software part")
        let top = VolumeCurve.split(1, base: base)
        check(top.software == 1 && close(top.hardware, 1), "full: monitor at 100%")
        check(close(VolumeCurve.split(0.875, base: base).hardware, 0.625), "halfway up the monitor part")
        // Round trips.
        for level: Float in [0, 0.1, 0.5, 0.75, 0.8, 0.9, 1] {
            let split = VolumeCurve.split(level, base: base)
            check(close(VolumeCurve.level(software: split.software, hardware: split.hardware, base: base), level), "round trip \(level)")
        }
        // A monitor already at 100% as its base: software only.
        check(VolumeCurve.split(1, base: 1) == .init(software: 1, hardware: 1), "base 100%")
        check(close(VolumeCurve.level(software: 0.5, hardware: 1, base: 1), 0.375), "base 100% level")

        // Hush's volume lowered from outside (Control Center) with the monitor raised:
        // the level follows the software volume, not the monitor.
        check(close(VolumeCurve.level(software: 0.3, hardware: 0.6, base: base), 0.225), "software lowered under a raised monitor")
        // From any state, a step down (or staying put) never makes either part louder.
        for software: Float in [0, 0.2, 0.3, 0.5, 0.9, 0.99, 1] {
            for hardware: Float in [0.25, 0.26, 0.4, 0.6, 1] {
                let level = VolumeCurve.level(software: software, hardware: hardware, base: base)
                for down: Float in [0, 1.0 / 64, 1.0 / 16, 0.5] {
                    let split = VolumeCurve.split(level - down, base: base)
                    check(split.software <= software + 0.001 && split.hardware <= hardware + 0.001,
                          "no louder from software \(software), monitor \(hardware), down \(down)")
                }
            }
        }
        // A base the monitor rounded to its own step is not mistaken for a raised monitor.
        check(close(VolumeCurve.level(software: 1, hardware: 0.3, base: 0.3), 0.75), "monitor exactly at its base")
    }

    static func zoneTable() {
        let table = "# comment\nGB\t+513030-0000731\tEurope/London\nJP\t+3541+13946\tAsia/Tokyo\n"
        let tokyo = TimeZoneLocation.coordinate(for: "Asia/Tokyo", in: table)
        check(tokyo.map { abs($0.latitude - 35.683) < 0.01 && abs($0.longitude - 139.767) < 0.01 } == true, "Tokyo coordinates")
        let london = TimeZoneLocation.coordinate(for: "Europe/London", in: table)
        check(london.map { abs($0.latitude - 51.508) < 0.01 && abs($0.longitude + 0.125) < 0.01 } == true, "London with seconds")
        check(TimeZoneLocation.coordinate(for: "Mars/Olympus", in: table) == nil, "unknown zone")
        check(TimeZoneLocation.parse("+٢٤٣٨+٠٤٦٤٣") == nil, "non-ASCII digits rejected, not crashed on")
        // The system's own table: a zone it lists, and an old name it doesn't
        // (macOS reports India as Asia/Calcutta; zone.tab only has Asia/Kolkata).
        check(TimeZoneLocation.location(of: "Asia/Tokyo") != nil, "system zone.tab")
        let kolkata = TimeZoneLocation.location(of: "Asia/Calcutta")
        check(kolkata.map { abs($0.latitude - 22.53) < 0.1 && abs($0.longitude - 88.37) < 0.1 } == true, "old zone name")
        check(TimeZoneLocation.location(of: "Mars/Olympus") == nil, "unknown system zone")
    }

    static func nightLevels() {
        // First launch by day: nothing fades, and the bright screen is not learned as the night level.
        var plan = NightLevels.plan(night: false, current: 0.8, savedDay: nil, savedNight: nil)
        check(plan.target == 0.8 && plan.learnDay == nil, "day, nothing saved")
        // Night starts: the day level is learned, the display goes to the default.
        plan = NightLevels.plan(night: true, current: 0.8, savedDay: nil, savedNight: nil)
        check(plan.target == NightLevels.defaultNight && plan.learnDay == 0.8, "night, nothing saved")
        // Saved levels win, and a saved day level is not overwritten.
        plan = NightLevels.plan(night: true, current: 0.6, savedDay: 0.8, savedNight: 0.3)
        check(plan.target == 0.3 && plan.learnDay == nil, "night, both saved")
        plan = NightLevels.plan(night: false, current: 0.3, savedDay: 0.8, savedNight: 0.3)
        check(plan.target == 0.8 && plan.learnDay == nil, "day, both saved")
        // A display already dimmer than the default night level is not brightened.
        plan = NightLevels.plan(night: true, current: 0.05, savedDay: 0.8, savedNight: nil)
        check(plan.target == 0.05, "night never brightens")
    }

    static func schedule() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let coordinate = CLLocationCoordinate2D(latitude: 35.683, longitude: 139.767)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour, minute: minute))!
        }
        // Tokyo, 24 Nov: sunrise about 06:20, sunset about 16:30.
        check(NightSchedule.sun.isNight(at: at(5, 0), timeZone: tokyo, coordinate: coordinate), "before sunrise")
        check(!NightSchedule.sun.isNight(at: at(12, 0), timeZone: tokyo, coordinate: coordinate), "noon")
        check(!NightSchedule.sun.isNight(at: at(16, 10), timeZone: tokyo, coordinate: coordinate), "just before sunset")
        check(NightSchedule.sun.isNight(at: at(16, 50), timeZone: tokyo, coordinate: coordinate), "after sunset")
        check(NightSchedule.sun.isNight(at: at(23, 30), timeZone: tokyo, coordinate: coordinate), "late night")
        // Far from UTC, the local day straddles two UTC days.
        for (zone, latitude, longitude) in [("America/Los_Angeles", 34.05, -118.24), ("Pacific/Auckland", -36.85, 174.76),
                                            ("Pacific/Honolulu", 21.31, -157.86), ("Asia/Tokyo", 35.68, 139.69)] {
            let timeZone = TimeZone(identifier: zone)!
            let place = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            var local = Calendar(identifier: .gregorian)
            local.timeZone = timeZone
            for (hour, night) in [(1, true), (4, true), (10, false), (13, false), (16, false), (22, true)] {
                let date = local.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour))!
                check(NightSchedule.sun.isNight(at: date, timeZone: timeZone, coordinate: place) == night, "\(zone) at \(hour):00")
            }
        }
        // No location: falls back to 9 PM–7 AM.
        check(NightSchedule.sun.isNight(at: at(22, 0), timeZone: tokyo, coordinate: nil), "fallback night")
        check(!NightSchedule.sun.isNight(at: at(18, 0), timeZone: tokyo, coordinate: nil), "fallback evening")

        let tenToSeven = NightSchedule.hours(start: 22 * 60, end: 7 * 60)
        check(tenToSeven.isNight(at: at(23, 0), timeZone: tokyo, coordinate: nil), "wrapping hours, late")
        check(tenToSeven.isNight(at: at(6, 59), timeZone: tokyo, coordinate: nil), "wrapping hours, early")
        check(!tenToSeven.isNight(at: at(7, 0), timeZone: tokyo, coordinate: nil), "wrapping hours end")
        let midnightToEight = NightSchedule.hours(start: 0, end: 8 * 60)
        check(midnightToEight.isNight(at: at(0, 30), timeZone: tokyo, coordinate: nil), "non-wrapping hours")
        check(!midnightToEight.isNight(at: at(23, 0), timeZone: tokyo, coordinate: nil), "non-wrapping hours, before")

        for preset in NightSchedule.presets {
            check(NightSchedule(storageValue: preset.storageValue) == preset, "storage round trip \(preset.storageValue)")
        }
        check(NightSchedule(storageValue: "99-x") == nil, "bad storage value")
    }
}
