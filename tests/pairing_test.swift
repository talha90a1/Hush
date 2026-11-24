// Checks DisplayPairing with made-up registry data for one and two monitors,
// and MCCS capabilities parsing.
//
//   mkdir -p build && swiftc -parse-as-library App/Sources/DisplayPairing.swift App/Sources/MCCS.swift tests/pairing_test.swift -o build/pairing_test && build/pairing_test
//
// SPDX-License-Identifier: MIT

import Foundation

@main
enum PairingTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func proxy(_ n: Int) -> String {
        "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dcpext\(n)@86E00000/AppleASCWrapV6/iop-dcpext\(n)-nub/RTBuddy(DCPEXT\(n))/DCPEXT\(n)Endpoint9/AFKDCPEXT\(n)Endpoint9/AFKEPInterfaceServiceKextV2/dispext\(n):dcpav-service-epic:0/DCPAVServiceProxy"
    }

    static func framebuffer(_ n: Int, vendor: UInt32, product: UInt32, serial: UInt32) -> DisplayPairing.Framebuffer {
        .init(path: "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dispext\(n)@84000000/IOMobileFramebufferShim",
              vendor: vendor, product: product, serial: serial)
    }

    static func main() {
        check(DisplayPairing.pipe(in: proxy(0)) == "dispext0", "pipe of proxy")
        check(DisplayPairing.pipe(in: framebuffer(1, vendor: 0, product: 0, serial: 0).path) == "dispext1", "pipe of framebuffer")
        check(DisplayPairing.pipe(in: "IOService:/AppleARMPE/disp0@8000000/IOMobileFramebufferShim") == nil, "built-in pipe ignored")

        // One monitor: paired even without registry details.
        check(DisplayPairing.pair(proxies: [proxy(0)], framebuffers: [],
                                  screens: [.init(id: 3, vendor: 1, product: 2, serial: 3)]) == [3], "single monitor")

        // Two different monitors, proxies listed in the opposite order to the screens.
        let dell = DisplayPairing.Screen(id: 3, vendor: 0x10AC, product: 0xA272, serial: 11)
        let lg = DisplayPairing.Screen(id: 5, vendor: 0x1E6D, product: 0x7750, serial: 22)
        let fbs = [framebuffer(0, vendor: 0x10AC, product: 0xA272, serial: 11),
                   framebuffer(1, vendor: 0x1E6D, product: 0x7750, serial: 22)]
        check(DisplayPairing.pair(proxies: [proxy(1), proxy(0)], framebuffers: fbs, screens: [dell, lg]) == [5, 3],
              "two different monitors")

        // Identical twins told apart by serial.
        let twinA = DisplayPairing.Screen(id: 7, vendor: 0x10AC, product: 0xA272, serial: 100)
        let twinB = DisplayPairing.Screen(id: 8, vendor: 0x10AC, product: 0xA272, serial: 200)
        let twinFBs = [framebuffer(0, vendor: 0x10AC, product: 0xA272, serial: 200),
                       framebuffer(1, vendor: 0x10AC, product: 0xA272, serial: 100)]
        check(DisplayPairing.pair(proxies: [proxy(0), proxy(1)], framebuffers: twinFBs, screens: [twinA, twinB]) == [8, 7],
              "identical twins by serial")

        // Identical twins without serials: can't tell, so neither is guessed.
        let noSerialFBs = [framebuffer(0, vendor: 0x10AC, product: 0xA272, serial: 0),
                           framebuffer(1, vendor: 0x10AC, product: 0xA272, serial: 0)]
        check(DisplayPairing.pair(proxies: [proxy(0), proxy(1)], framebuffers: noSerialFBs, screens: [twinA, twinB]) == [nil, nil],
              "ambiguous twins left unpaired")

        // The usual twins without serials: every side reports 0, which matches
        // both screens and so singles out neither.
        let blankA = DisplayPairing.Screen(id: 7, vendor: 0x10AC, product: 0xA272, serial: 0)
        let blankB = DisplayPairing.Screen(id: 8, vendor: 0x10AC, product: 0xA272, serial: 0)
        check(DisplayPairing.pair(proxies: [proxy(0), proxy(1)], framebuffers: noSerialFBs, screens: [blankA, blankB]) == [nil, nil],
              "twins that all report serial 0 left unpaired")

        // A proxy whose framebuffer is missing.
        check(DisplayPairing.pair(proxies: [proxy(0), proxy(2)], framebuffers: fbs, screens: [dell, lg]) == [3, nil],
              "missing framebuffer")

        // Capabilities strings.
        let dellCaps = "(prot(monitor)type(LCD)model(S2725QC)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 05 08 0B 0C) 16 18 1A 52 60(1B 11 12 ) 62(FF FE) 63(FF FD ) 87)mccs_ver(2.1))"
        check(MCCS.inputCodes(in: dellCaps) == [0x1B, 0x11, 0x12], "Dell input list")
        check(MCCS.inputCodes(in: "(vcp(10 12 160(01 02) 60(0F 11)))") == [0x0F, 0x11], "60( not matched inside 160(")
        check(MCCS.inputCodes(in: "(vcp(10 12 62))") == [], "no input list")
        check(MCCS.inputCodes(in: "(model(X)cmds(60(01)))") == [], "60( outside vcp ignored")
        check(MCCS.Input(code: 0x1B).name == "USB-C" && MCCS.Input(code: 0x11).name == "HDMI 1", "input names")

        print(failures == 0 ? "PASS" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
