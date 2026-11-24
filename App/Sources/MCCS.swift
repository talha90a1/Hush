// Pure helpers for the VESA MCCS (DDC/CI) protocol, kept free of IOKit so
// they can be tested without a monitor.
//
// SPDX-License-Identifier: MIT

import Foundation

enum MCCS {
    struct Input {
        let code: UInt8
        var name: String {
            switch code {
            case 0x01: return "VGA 1"
            case 0x02: return "VGA 2"
            case 0x03: return "DVI 1"
            case 0x04: return "DVI 2"
            case 0x0F: return "DisplayPort 1"
            case 0x10: return "DisplayPort 2"
            case 0x11: return "HDMI 1"
            case 0x12: return "HDMI 2"
            case 0x1B: return "USB-C"
            default: return String(format: "Input 0x%02X", code)
            }
        }
    }

    /// Input codes from the `60(…)` entry of a capabilities string's vcp list.
    static func inputCodes(in capabilities: String) -> [UInt8] {
        guard let start = capabilities.range(of: "vcp(") else { return [] }
        let vcp = capabilities[start.upperBound...]
        // Find "60(" as its own token, not inside another code like "160(".
        var search = vcp.startIndex
        while let range = vcp.range(of: "60(", range: search..<vcp.endIndex) {
            let before = range.lowerBound == vcp.startIndex ? " " : vcp[vcp.index(before: range.lowerBound)]
            if before == " " || before == "(" || before == ")" {
                let list = vcp[range.upperBound...].prefix { $0 != ")" }
                return list.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            }
            search = range.upperBound
        }
        return []
    }
}
