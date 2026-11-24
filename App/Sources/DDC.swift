// DDC/CI control of external displays on Apple Silicon: brightness, contrast,
// the monitor's own speaker volume and input source. Protocol details follow the
// VESA MCCS spec and the approach documented by MonitorControl (MIT) and m1ddc.
//
// SPDX-License-Identifier: MIT

import AppKit
import IOKit

final class DDCDisplay {
    enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case input = 0x60
        case speakerVolume = 0x62
    }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt8 = 0x51

    let service: IOAVService
    let name: String
    let displayID: CGDirectDisplayID
    /// Stable per monitor, for saved settings.
    let key: String
    private let queue = DispatchQueue(label: "hush.ddc")
    private let lock = NSLock()
    private var pending: [UInt8: UInt16] = [:] // newest unwritten value per VCP code
    private var unsent: Set<UInt8> = [] // VCP codes whose last write failed

    /// Current and maximum of every control that answered a read.
    private var values: [VCP: (current: UInt16, max: UInt16)] = [:]
    private(set) var brightnessMax: UInt16 = 100
    private(set) var brightness: UInt16 = 50
    /// Inputs listed in the monitor's capabilities string; empty when it lists none.
    private(set) var inputs: [MCCS.Input] = []
    private(set) var currentInput: UInt8?

    private init(service: IOAVService, name: String, displayID: CGDirectDisplayID) {
        self.service = service
        self.name = name
        self.displayID = displayID
        key = "display-\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
    }

    // MARK: Discovery

    /// Discovery runs here, one at a time: two at once would mix their I2C
    /// traffic on the same bus and read each other's replies.
    static let discoveryQueue = DispatchQueue(label: "hush.ddc.discovery", qos: .userInitiated)

    /// Every external display reachable over DDC, paired to its screen. Reads each
    /// control once (blocking: call on `discoveryQueue`, never on the main thread,
    /// which it waits for). Many monitors and HDMI ports accept writes but return
    /// garbage on reads, so a failed brightness read is not fatal: we fall back to
    /// the last value we set.
    static func findAll() -> [DDCDisplay] {
        let all = services(matching: "DCPAVServiceProxy")
        defer { all.forEach { IOObjectRelease($0.entry) } }
        let proxies = all.filter {
            (IORegistryEntryCreateCFProperty($0.entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) == "External"
        }

        let framebuffers: [DisplayPairing.Framebuffer] = services(matching: "IOMobileFramebufferShim").compactMap { fb in
            defer { IOObjectRelease(fb.entry) }
            let attributes = IORegistryEntryCreateCFProperty(fb.entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            guard let product = attributes?["ProductAttributes"] as? [String: Any] else { return nil }
            func number(_ key: String) -> UInt32 { (product[key] as? NSNumber)?.uint32Value ?? 0 }
            return .init(path: fb.path, vendor: number("LegacyManufacturerID"), product: number("ProductID"), serial: number("SerialNumber"))
        }

        let screens = externalDisplayIDs().map {
            DisplayPairing.Screen(id: $0, vendor: CGDisplayVendorNumber($0), product: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0))
        }
        let pairs = DisplayPairing.pair(proxies: proxies.map(\.path), framebuffers: framebuffers, screens: screens)
        // AppKit belongs to the main thread.
        let names = DispatchQueue.main.sync {
            Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.localizedName) } }) { first, _ in first }
        }

        return zip(proxies, pairs).compactMap { proxy, displayID in
            guard let displayID, let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, proxy.entry)?.takeRetainedValue() else { return nil }
            let display = DDCDisplay(service: svc, name: names[displayID] ?? "Monitor", displayID: displayID)
            display.readAll()
            return display
        }
    }

    private func readAll() {
        for vcp in [VCP.brightness, .contrast, .speakerVolume] {
            if let reply = read(vcp.rawValue), reply.max > 0 { values[vcp] = (min(reply.current, reply.max), reply.max) }
        }
        if let (current, maximum) = values[.brightness] {
            brightnessMax = maximum
            brightness = current
        } else {
            let saved = UserDefaults.standard.object(forKey: key + ".brightness") as? Double ?? 0.5
            brightness = UInt16((saved * Double(brightnessMax)).rounded())
        }
        if let caps = capabilities() {
            inputs = MCCS.inputCodes(in: caps).map(MCCS.Input.init)
            if !inputs.isEmpty, let reply = read(VCP.input.rawValue) {
                currentInput = UInt8(reply.current & 0xFF) // some monitors repeat the code in the high byte
            }
        }
        Log.info("DDC \(name): \(values.keys.map { String(format: "0x%02X", $0.rawValue) }.sorted()) inputs=\(inputs.map(\.name))")
    }

    // MARK: Controls

    var normalizedBrightness: Float { Float(brightness) / Float(brightnessMax) }

    func setBrightness(normalized: Float) {
        brightness = UInt16((max(0, min(1, normalized)) * Float(brightnessMax)).rounded())
        UserDefaults.standard.set(Double(normalizedBrightness), forKey: key + ".brightness")
        enqueue(VCP.brightness.rawValue, brightness)
    }

    /// True when the monitor answered a read for this control (brightness is
    /// always offered, since many monitors only accept writes for it).
    func supports(_ vcp: VCP) -> Bool { vcp == .brightness || values[vcp] != nil }

    /// How many controls answered a read. Fewer than before means the monitor
    /// was not ready (it wakes slower than the Mac), not that it lost them.
    var answered: Int { values.count }

    /// `normalized` snapped to a step this control has; unchanged if it never answered.
    func quantized(_ vcp: VCP, _ normalized: Float) -> Float {
        guard let maximum = values[vcp]?.max else { return normalized }
        return (max(0, min(1, normalized)) * Float(maximum)).rounded() / Float(maximum)
    }

    func normalized(_ vcp: VCP) -> Float? {
        guard let (current, maximum) = values[vcp] else { return nil }
        return Float(current) / Float(maximum)
    }

    /// Skips the write when the monitor already has that value, unless the last
    /// write failed or `force` is set.
    func set(_ vcp: VCP, normalized: Float, force: Bool = false) {
        guard let (current, maximum) = values[vcp] else { return }
        let value = UInt16((max(0, min(1, normalized)) * Float(maximum)).rounded())
        guard force || value != current || lock.withLock({ unsent.contains(vcp.rawValue) }) else { return }
        values[vcp]?.current = value
        enqueue(vcp.rawValue, value)
    }

    /// Writes now and waits, after any queued writes: for app exit, where a
    /// queued write would be lost. Always writes: what we believe the monitor
    /// has may be wrong (its own buttons, a write it dropped), and this is the
    /// last chance to leave it at a safe level.
    func setAndWait(_ vcp: VCP, normalized: Float) {
        set(vcp, normalized: normalized, force: true)
        queue.sync {}
    }

    /// Switches the monitor to another input. The Mac usually loses the picture
    /// (and DDC) once it does, so this is only ever sent from a confirmed click.
    func switchInput(to code: UInt8) {
        currentInput = code
        queue.async { [self] in _ = write(VCP.input.rawValue, value: UInt16(code)) }
    }

    /// Coalesces rapid changes (key repeat, slider drags): while a write for a
    /// control is queued, newer values replace it instead of piling up.
    private func enqueue(_ vcp: UInt8, _ value: UInt16) {
        let alreadyQueued = lock.withLock { pending.updateValue(value, forKey: vcp) != nil }
        guard !alreadyQueued else { return }
        queue.async { [self] in
            guard let latest = lock.withLock({ pending.removeValue(forKey: vcp) }) else { return }
            let sent = write(vcp, value: latest)
            lock.withLock { if sent { unsent.remove(vcp) } else { unsent.insert(vcp) } }
        }
    }

    // MARK: DDC transport

    private func write(_ vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(UInt8(Self.chipAddress << 1) ^ Self.dataAddress, packet[0..<5])
        for _ in 0..<3 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(Self.dataAddress), &packet, UInt32(packet.count)) == 0 { return true }
        }
        return false
    }

    private func read(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(UInt8(Self.chipAddress << 1), packet[0..<3])
        var reply = [UInt8](repeating: 0, count: 11)
        for _ in 0..<4 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(Self.dataAddress), &packet, UInt32(packet.count)) == 0 else { continue }
            usleep(50_000)
            guard IOAVServiceReadI2C(service, Self.chipAddress, 0, &reply, UInt32(reply.count)) == 0 else { continue }
            guard checksum(0x50, reply[0..<10]) == reply[10], reply[2] == 0x02, reply[3] == 0, reply[4] == vcp else { continue }
            return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return nil
    }

    /// The MCCS capabilities string, read in chunks; nil if the monitor doesn't answer.
    private func capabilities() -> String? {
        var bytes: [UInt8] = []
        var offset: UInt16 = 0
        while offset < 2048 {
            var packet: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF), 0]
            packet[4] = checksum(UInt8(Self.chipAddress << 1) ^ Self.dataAddress, packet[0..<4])
            var chunk: ArraySlice<UInt8>?
            for _ in 0..<5 where chunk == nil {
                usleep(20_000)
                guard IOAVServiceWriteI2C(service, Self.chipAddress, UInt32(Self.dataAddress), &packet, UInt32(packet.count)) == 0 else { continue }
                usleep(60_000)
                var reply = [UInt8](repeating: 0, count: 38)
                guard IOAVServiceReadI2C(service, Self.chipAddress, 0, &reply, UInt32(reply.count)) == 0 else { continue }
                let length = Int(reply[1] & 0x7F)
                guard (3...35).contains(length), reply[2] == 0xE3,
                      checksum(0x50, reply[0..<(2 + length)]) == reply[2 + length],
                      UInt16(reply[3]) << 8 | UInt16(reply[4]) == offset else { continue }
                chunk = reply[5..<(2 + length)]
            }
            guard let chunk else { return nil }
            if chunk.isEmpty { break }
            bytes += chunk
            offset += UInt16(chunk.count)
        }
        let text = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    // MARK: Registry and screens

    private static func services(matching className: String) -> [(entry: io_service_t, path: String)] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(io_service_t, String)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var path = [CChar](repeating: 0, count: 1024)
            IORegistryEntryGetPath(entry, kIOServicePlane, &path)
            result.append((entry, String(cString: path)))
        }
        return result
    }

    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }
}

extension NSScreen {
    /// The CoreGraphics display this screen shows.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
