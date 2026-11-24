// When "night" is, for night dimming: sunset to sunrise where the Mac is, or
// fixed hours. The location comes from the time zone's reference city in the
// system's zone.tab, so no Location Services permission is needed.
//
// SPDX-License-Identifier: MIT

import CoreLocation
import Foundation

enum NightSchedule: Equatable {
    /// Sunset to sunrise.
    case sun
    /// Fixed local hours, in minutes after midnight; may wrap past midnight.
    case hours(start: Int, end: Int)

    static let presets: [NightSchedule] = [
        .sun, .hours(start: 21 * 60, end: 7 * 60), .hours(start: 22 * 60, end: 7 * 60),
        .hours(start: 23 * 60, end: 7 * 60), .hours(start: 0, end: 8 * 60),
    ]

    /// Used when sunset/sunrise can't be worked out (unknown zone, polar day or night).
    private static let fallback = NightSchedule.hours(start: 21 * 60, end: 7 * 60)

    var title: String {
        switch self {
        case .sun: return "Sunset to Sunrise"
        case let .hours(start, end): return "\(Self.clock(start)) to \(Self.clock(end))"
        }
    }

    // MARK: Storage

    var storageValue: String {
        switch self {
        case .sun: return "sun"
        case let .hours(start, end): return "\(start)-\(end)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "sun" { self = .sun; return }
        let parts = storageValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ (0..<1440).contains($0) }) else { return nil }
        self = .hours(start: parts[0], end: parts[1])
    }

    // MARK: Night or day

    func isNight(at date: Date, timeZone: TimeZone, coordinate: CLLocationCoordinate2D?) -> Bool {
        switch self {
        case .sun:
            guard let coordinate, let solar = Solar(for: date, coordinate: coordinate),
                  solar.sunrise != nil, solar.sunset != nil else {
                return Self.fallback.isNight(at: date, timeZone: timeZone, coordinate: nil)
            }
            return solar.isNighttime
        case let .hours(start, end):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            return start <= end ? (start..<end).contains(minute) : (minute >= start || minute < end)
        }
    }

    private static func clock(_ minutes: Int) -> String {
        var parts = DateComponents()
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        let date = Calendar(identifier: .gregorian).date(from: parts) ?? Date()
        let format = DateFormatter()
        format.timeStyle = .short
        format.dateStyle = .none
        return format.string(from: date)
    }
}

/// Which brightness night dimming fades a display to. Pure, so it can be tested.
enum NightLevels {
    /// Night level for a display nobody has set one for: a little below the
    /// backlight's lowest, using the dimming overlay.
    static let defaultNight: Float = 0.15

    /// `target`: the level for the part of the day that is starting.
    /// `learnDay`: a day level to remember, when night starts and none is saved:
    /// what is on screen then is the day brightness. The night level is never
    /// learned this way: by day the screen is bright, and saving that as the
    /// night level would switch the dimming off for good.
    static func plan(night: Bool, current: Float, savedDay: Float?, savedNight: Float?) -> (target: Float, learnDay: Float?) {
        guard night else { return (savedDay ?? current, nil) }
        // Never brighter than it already is, for a display kept very dim.
        return (savedNight ?? min(defaultNight, current), savedDay == nil ? current : nil)
    }
}

enum TimeZoneLocation {
    private static let zoneinfo = "/usr/share/zoneinfo/"

    /// The reference city of a time zone, from the system's zone.tab.
    static func location(of zone: String) -> CLLocationCoordinate2D? {
        guard let table = try? String(contentsOfFile: zoneinfo + "zone.tab", encoding: .utf8) else { return nil }
        if let found = coordinate(for: zone, in: table) { return found }
        // macOS still names some zones the old way ("Asia/Calcutta", "Europe/Kiev"),
        // and zone.tab lists only the new name: find the listed zone with the same rules.
        guard let rules = FileManager.default.contents(atPath: zoneinfo + zone) else { return nil }
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, FileManager.default.contents(atPath: zoneinfo + fields[2]) == rules else { continue }
            return parse(String(fields[1]))
        }
        return nil
    }

    /// Looks up a zone in zone.tab text ("JP\t+3541+13946\tAsia/Tokyo").
    static func coordinate(for zone: String, in table: String) -> CLLocationCoordinate2D? {
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == zone else { continue }
            return parse(String(fields[1]))
        }
        return nil
    }

    /// ISO 6709 "+DDMM+DDDMM" or "+DDMMSS+DDDMMSS".
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let latitude = degrees(String(text[..<split]), degreeDigits: 2),
              let longitude = degrees(String(text[split...]), degreeDigits: 3) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private static func degrees(_ text: String, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        func number(_ range: Range<Int>) -> Double { Double(String(digits[range]))! }
        var value = number(0..<degreeDigits) + number(degreeDigits..<(degreeDigits + 2)) / 60
        if digits.count == degreeDigits + 4 { value += number((degreeDigits + 2)..<(degreeDigits + 4)) / 3600 }
        return sign == "-" ? -value : value
    }
}
