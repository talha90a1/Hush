// Pairs each DDC service (DCPAVServiceProxy) with the screen it controls.
//
// On Apple Silicon both sit under the same display pipe in the IORegistry:
//   …/dispext0@84000000/IOMobileFramebufferShim             (has the EDID identity)
//   …/dcpext0@…/…/dispext0:dcpav-service-epic:0/DCPAVServiceProxy
// so the "dispextN" name joins them, and the framebuffer's vendor/product/serial
// joins it to the CGDirectDisplayID. Pure logic, so it can be tested without hardware.
//
// SPDX-License-Identifier: MIT

import Foundation

enum DisplayPairing {
    struct Framebuffer {
        let path: String
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    struct Screen {
        let id: UInt32
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    /// The display pipe name in a registry path ("dispext0"), or nil.
    static func pipe(in path: String) -> String? {
        for component in path.split(separator: "/") {
            let name = component.prefix { $0 != "@" && $0 != ":" }
            if name.hasPrefix("dispext"), name.dropFirst(7).allSatisfy(\.isNumber), name.count > 7 {
                return String(name)
            }
        }
        return nil
    }

    /// For each proxy path, the screen it controls (nil when it can't be told).
    /// With exactly one proxy and one external screen, they belong together.
    static func pair(proxies: [String], framebuffers: [Framebuffer], screens: [Screen]) -> [UInt32?] {
        if proxies.count == 1, screens.count == 1 { return [screens[0].id] }
        var used = Set<UInt32>()
        return proxies.map { proxy in
            guard let pipe = pipe(in: proxy),
                  let fb = framebuffers.first(where: { Self.pipe(in: $0.path) == pipe }) else { return nil }
            let candidates = screens.filter { $0.vendor == fb.vendor && $0.product == fb.product && !used.contains($0.id) }
            // Identical twin monitors: the serial tells them apart when the monitor
            // reports one. Twins that both report none (0) are not guessed.
            let bySerial = candidates.filter { $0.serial == fb.serial }
            let match = bySerial.count == 1 ? bySerial[0] : (candidates.count == 1 ? candidates[0] : nil)
            if let match { used.insert(match.id) }
            return match?.id
        }
    }
}
