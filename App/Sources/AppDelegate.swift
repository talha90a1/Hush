// Menu bar UI and glue.
// SPDX-License-Identifier: MIT

import AppKit
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let audio = AudioRouter()
    private let updates = Updates()
    private let keys = MediaKeys()
    private var displays: [DDCDisplay] = []
    private var displaySliders: [CGDirectDisplayID: DisplaySliders] = [:]
    private let nightMode = NightMode()
    /// Counts display searches, so only the newest one's result is used.
    private var search = 0
    /// Most controls each monitor (by `key`) has answered a read for.
    private var answered: [String: Int] = [:]
    private var quitSignal: DispatchSourceSignal?

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private static let menuWidth: CGFloat = 280
    private static let sliderWidth = menuWidth - 32
    private let volumeSlider = ModuleSlider(style: .volume, width: sliderWidth)

    private struct DisplaySliders {
        let brightness: ModuleSlider
        let contrast: ModuleSlider?
        let speaker: ModuleSlider?
    }

    /// The bottom of the brightness range dims with an overlay once the
    /// monitor's own backlight is at its lowest.
    private static let dimZone: Float = 0.2

    /// Steps per key press across the whole range, like macOS; ⇧⌥ gives quarter steps.
    private static let keySteps: Float = 16
    private static let fineSteps = keySteps * 4
    private static let searchRetries = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = updates.controller // starts the scheduled update checks
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Hush")
        menu.delegate = self
        statusItem.menu = menu

        volumeSlider.onChange = { [weak self] value in
            guard let self else { return }
            self.setVolumeLevel(value)
            if self.audio.muted { self.audio.muted = false }
        }

        nightMode.displays = { [weak self] in self?.displays ?? [] }
        nightMode.level = { [weak self] display in self?.level(of: display) ?? 0 }
        nightMode.apply = { [weak self] level, display in
            self?.setLevel(level, of: display.displayID)
            self?.displaySliders[display.displayID]?.brightness.value = level
        }
        nightMode.start()

        audio.onChange = { [weak self] in self?.refreshControls() }
        audio.start()

        findDisplays(after: 0)
        Log.info("accessibility trusted: \(MediaKeys.hasAccessibility)")

        keys.handler = { [weak self] key, fine in
            if key.isBrightness { self?.handleBrightnessKey(key, fine: fine) } else { self?.handleVolumeKey(key, fine: fine) }
        }
        if MediaKeys.hasAccessibility {
            keys.start()
        } else {
            MediaKeys.requestAccessibility()
            pollForAccessibility()
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        enableLoginOnce()
        quitOnSIGTERM()

        if DriverInstaller.needsInstall {
            DispatchQueue.main.async { [weak self] in self?.offerDriverInstall() }
        }
    }

    /// Without the app running, a restart leaves the Mac on its own speakers,
    /// so the first launch of the installed app turns "open at login" on.
    /// Only once: turning it off in the menu sticks.
    private func enableLoginOnce() {
        let key = "loginItemSet"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { toggleLogin() }
    }

    /// `pkill Hush` (install.sh, uninstall.sh) and `kill` would end the app without
    /// `applicationWillTerminate`, leaving the monitor's speakers raised with
    /// nothing in front of them. Quit the normal way instead.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        quitSignal = source
    }

    // MARK: Driver

    private func offerDriverInstall() {
        let update = DriverInstaller.isInstalled
        let alert = NSAlert()
        alert.messageText = update ? "Update the audio driver" : "Install the audio driver"
        alert.informativeText = "Hush uses a virtual audio device so the volume keys work with your monitor or TV. macOS will ask for your password, and sound will cut out for a moment."
        alert.addButton(withTitle: update ? "Update" : "Install")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installDriver()
    }

    @objc private func installDriver() {
        stopAudio()
        guard DriverInstaller.install() else { audio.start(); return }
        relaunch()
    }

    /// CoreAudio restarts after a driver change; a fresh process picks up the new device cleanly.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    @objc private func uninstallHush() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Hush?"
        alert.informativeText = "The audio driver and the app will be removed. macOS will ask for your password."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopAudio()
        guard DriverInstaller.uninstall() else { audio.start(); return }
        try? SMAppService.mainApp.unregister()
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAudio()
    }

    /// Hush lets go of the audio (quit, driver install or removal). Without Hush
    /// the Mac sends full-volume audio, so the speakers go to their safe level
    /// first, and only then does the monitor become the output again.
    private func stopAudio() {
        if Settings.oneVolumeControl {
            for display in displays where display.supports(.speakerVolume) {
                display.setAndWait(.speakerVolume, normalized: display.speakerBase)
            }
        }
        audio.stop()
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if MediaKeys.hasAccessibility { self.keys.start() } else { self.pollForAccessibility() }
        }
    }

    /// After a wake or a display change, give the display a moment, then find
    /// it again for DDC and let the audio route catch up.
    @objc private func displaysChanged() {
        Dimmer.shared.refresh()
        nightMode.check() // also catches day/night changing while asleep
        findDisplays(after: 2)
    }

    /// Wake and screen changes arrive in bursts: only the newest search reads the
    /// monitors, and searches run one at a time.
    private func findDisplays(after delay: TimeInterval, retry: Int = 0) {
        search += 1
        let current = search
        DDCDisplay.discoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard DispatchQueue.main.sync(execute: { self?.search == current }) else { return }
            let found = DDCDisplay.findAll()
            Log.info("DDC displays: \(found.map { "\($0.name) id=\($0.displayID) controls=\($0.answered)" })")
            DispatchQueue.main.async {
                guard let self, self.search == current else { return }
                self.setDisplays(found)
                self.retryIfIncomplete(found, retry: retry)
            }
        }
    }

    /// A monitor wakes slower than the Mac and may not answer yet. Without its
    /// answers there is no speaker control, so the one-volume control and the
    /// safe level on quit would silently stop working: look again a few times.
    private func retryIfIncomplete(_ found: [DDCDisplay], retry: Int) {
        let external = NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID ?? 0) == 0 }
        let incomplete = found.isEmpty ? external : found.contains { $0.answered < answered[$0.key] ?? 1 }
        if incomplete, retry < Self.searchRetries {
            findDisplays(after: 4, retry: retry + 1)
            return
        }
        // Settled. A monitor that never answers (many only accept writes) is
        // remembered as such, so it isn't searched for again after every change.
        for display in found { answered[display.key] = max(display.answered, answered[display.key] ?? 0) }
    }

    private func setDisplays(_ found: [DDCDisplay]) {
        displays = found
        displaySliders = [:]
        Dimmer.shared.keep(only: Set(found.map(\.displayID)))
        for display in found {
            let id = display.displayID
            let brightness = ModuleSlider(style: .brightness, width: Self.sliderWidth)
            brightness.onChange = { [weak self] value in self?.userSetLevel(value, of: id) }
            let contrast = display.supports(.contrast) ? ModuleSlider(style: .contrast, width: Self.sliderWidth) : nil
            contrast?.onChange = { [weak display] value in display?.set(.contrast, normalized: value) }
            let speaker = display.supports(.speakerVolume) ? ModuleSlider(style: .speaker, width: Self.sliderWidth) : nil
            speaker?.onChange = { [weak self, weak display] value in
                guard let self, let display else { return }
                if Settings.oneVolumeControl {
                    let level = self.volumeLevel
                    display.speakerBase = value
                    // Not playing through this monitor: it just waits at its safe level.
                    if display === self.speakerDisplay { self.setVolumeLevel(level) } else { display.set(.speakerVolume, normalized: value) }
                } else {
                    display.set(.speakerVolume, normalized: value)
                }
            }
            // Start from the safe level: the Sound slider takes it from there.
            if speaker != nil, Settings.oneVolumeControl { display.set(.speakerVolume, normalized: display.speakerBase) }
            displaySliders[id] = DisplaySliders(brightness: brightness, contrast: contrast, speaker: speaker)
            // The overlay only goes with the backlight at its lowest; a display ID
            // can also come back as a different monitor.
            let savedDim = UserDefaults.standard.float(forKey: display.key + ".dim")
            Dimmer.shared.setDepth(display.brightness == 0 ? savedDim : 0, for: id)
        }
        nightMode.reset()
        audio.evaluate() // ends in refreshControls()
    }

    private func display(_ displayID: CGDirectDisplayID) -> DDCDisplay? {
        displays.first { $0.displayID == displayID }
    }

    // MARK: Brightness

    private func handleBrightnessKey(_ key: MediaKeys.Key, fine: Bool) {
        // The tap only takes the key with the pointer on a DDC display.
        guard let display = display(pointerDisplayID) else { return }
        let value = Self.step(level(of: display), up: key == .brightnessUp, fine: fine)
        userSetLevel(value, of: display.displayID)
        HUD.shared.show(.brightness, level: value, on: display.displayID)
        displaySliders[display.displayID]?.brightness.value = value
    }

    /// One brightness scale per display: the monitor's backlight above `dimZone`,
    /// the dimming overlay below it.
    private func level(of display: DDCDisplay) -> Float {
        let dim = Dimmer.shared.depth(of: display.displayID)
        if dim > 0 { return Self.dimZone * (1 - dim) }
        return Self.dimZone + display.normalizedBrightness * (1 - Self.dimZone)
    }

    /// A brightness the user chose (not night mode's fade): night mode learns it.
    private func userSetLevel(_ value: Float, of displayID: CGDirectDisplayID) {
        setLevel(value, of: displayID)
        if let display = display(displayID) { nightMode.userSetLevel(value, of: display) }
    }

    private func setLevel(_ value: Float, of displayID: CGDirectDisplayID) {
        guard let display = display(displayID) else { return }
        let dim: Float
        if value >= Self.dimZone {
            dim = 0
            display.setBrightness(normalized: (value - Self.dimZone) / (1 - Self.dimZone))
        } else {
            dim = 1 - value / Self.dimZone
            if display.brightness != 0 { display.setBrightness(normalized: 0) }
        }
        Dimmer.shared.setDepth(dim, for: displayID)
        UserDefaults.standard.set(dim, forKey: display.key + ".dim")
    }

    private static func step(_ value: Float, up: Bool, fine: Bool) -> Float {
        let steps = fine ? fineSteps : keySteps
        return max(0, min(1, ((value * steps).rounded() + (up ? 1 : -1)) / steps))
    }

    // MARK: Volume

    private func handleVolumeKey(_ key: MediaKeys.Key, fine: Bool) {
        guard audio.isActiveOutput else { return }
        var value = volumeLevel
        if key == .mute {
            audio.muted.toggle()
        } else {
            value = Self.step(value, up: key == .volumeUp, fine: fine)
            setVolumeLevel(value)
            if audio.muted { audio.muted = false }
        }
        let muted = audio.muted || value == 0
        HUD.shared.show(muted ? .mute : .volume, level: value, on: pointerDisplayID)
        volumeSlider.value = value
        volumeSlider.muted = audio.muted
    }

    /// The monitor whose speakers Hush is playing through, when the one-volume
    /// control drives them too.
    private var speakerDisplay: DDCDisplay? {
        guard Settings.oneVolumeControl, audio.isActiveOutput, let target = audio.target else { return nil }
        let candidates = displays.filter { $0.supports(.speakerVolume) }
        return candidates.first { $0.name == CA.name(target) } ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    /// The Sound slider's position: Hush's volume, plus the monitor's speakers on top.
    private var volumeLevel: Float {
        guard let display = speakerDisplay, let hardware = display.normalized(.speakerVolume) else { return audio.volume }
        return VolumeCurve.level(software: audio.volume, hardware: hardware, base: display.speakerBase)
    }

    private func setVolumeLevel(_ level: Float) {
        guard let display = speakerDisplay else { audio.volume = level; return }
        let split = VolumeCurve.split(level, base: display.speakerBase)
        audio.volume = split.software
        display.set(.speakerVolume, normalized: split.hardware)
    }

    /// Display the pointer is on: where brightness keys act and the bezel shows.
    private var pointerDisplayID: CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    /// Sliders, and which keys Hush takes: brightness on DDC displays,
    /// volume only while Hush is the output (otherwise macOS handles them).
    private func refreshControls() {
        volumeSlider.value = volumeLevel
        volumeSlider.muted = audio.muted
        for display in displays {
            guard let sliders = displaySliders[display.displayID] else { continue }
            sliders.brightness.value = level(of: display)
            sliders.contrast?.value = display.normalized(.contrast) ?? 0
            sliders.speaker?.value = Settings.oneVolumeControl ? display.speakerBase : display.normalized(.speakerVolume) ?? 0
        }
        keys.take(brightnessIn: displays.map { CGDisplayBounds($0.displayID) }, volume: audio.isActiveOutput)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshControls()

        if audio.driverInstalled {
            menu.addItem(header("Sound"))
            menu.addItem(sliderItem(volumeSlider))
            let status: String
            if let t = audio.target {
                status = "Playing through \(CA.name(t))"
            } else if audio.isAwaitingTarget {
                status = "Waiting: returns to the monitor when it turns on"
            } else {
                status = "Inactive: the current output has its own volume"
            }
            menu.addItem(note(status))
        } else {
            menu.addItem(note("Hush audio driver is missing"))
            if DriverInstaller.bundledURL != nil {
                let item = NSMenuItem(title: "Install Audio Driver…", action: #selector(installDriver), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if displays.isEmpty {
            menu.addItem(note("Brightness: no external monitor responds over DDC"))
        }
        for display in displays {
            addDisplaySection(display, to: menu)
        }
        if !displays.isEmpty, !MediaKeys.hasAccessibility {
            let item = NSMenuItem(title: "Allow Brightness Keys (Accessibility)…", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let outputs = NSMenuItem(title: "Sound Output", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = audio.target ?? CA.defaultOutput
        for dev in audio.outputDevices() {
            let item = NSMenuItem(title: CA.name(dev), action: #selector(selectOutput(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(dev)
            item.state = (dev == current) ? .on : .off
            sub.addItem(item)
        }
        outputs.submenu = sub
        menu.addItem(outputs)

        menu.addItem(settingsItem())

        menu.addItem(.separator())
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updates.controller
        menu.addItem(check)
        let uninstall = NSMenuItem(title: "Uninstall Hush…", action: #selector(uninstallHush), keyEquivalent: "")
        uninstall.target = self
        menu.addItem(uninstall)
        let quit = NSMenuItem(title: "Quit Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addDisplaySection(_ display: DDCDisplay, to menu: NSMenu) {
        guard let sliders = displaySliders[display.displayID] else { return }
        menu.addItem(header("Display · \(display.name)"))
        menu.addItem(sliderItem(sliders.brightness))

        // Less-used controls live one level down.
        let more = NSMenu()
        if let contrast = sliders.contrast {
            more.addItem(caption("Contrast"))
            more.addItem(sliderItem(contrast))
        }
        if let speaker = sliders.speaker {
            more.addItem(caption(Settings.oneVolumeControl ? "Monitor speakers: safe level" : "Monitor speakers"))
            more.addItem(sliderItem(speaker))
            if Settings.oneVolumeControl {
                more.addItem(caption("Used below 75% on the Sound slider and when Hush quits"))
            }
        }
        if !display.inputs.isEmpty {
            if more.numberOfItems > 0 { more.addItem(.separator()) }
            more.addItem(caption("Input"))
            for input in display.inputs {
                let item = NSMenuItem(title: input.name, action: #selector(selectInput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (display.displayID, input.code) as (CGDirectDisplayID, UInt8)
                item.state = input.code == display.currentInput ? .on : .off
                more.addItem(item)
            }
        }
        if more.numberOfItems > 0 {
            let item = NSMenuItem(title: "More Controls", action: nil, keyEquivalent: "")
            item.submenu = more
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private func settingsItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false // or the schedules stay clickable with night dimming off
        func toggle(_ title: String, _ on: Bool, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            sub.addItem(item)
        }

        toggle("One Volume Control", Settings.oneVolumeControl, #selector(toggleOneVolume))
        sub.addItem(caption("Sound slider also drives the monitor's speakers above 75%"))

        sub.addItem(.separator())
        toggle("Night Dimming", Settings.nightDimming, #selector(toggleNightDimming))
        for schedule in NightSchedule.presets {
            let item = NSMenuItem(title: schedule.title, action: #selector(selectSchedule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = schedule.storageValue
            item.state = schedule == Settings.nightSchedule ? .on : .off
            item.indentationLevel = 1
            item.isEnabled = Settings.nightDimming
            sub.addItem(item)
        }
        sub.addItem(caption("Remembers the brightness you set at night and by day"))

        sub.addItem(.separator())
        toggle("Open at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        toggle("Install Updates Automatically", updates.controller.updater.automaticallyDownloadsUpdates, #selector(toggleAutomaticUpdates))

        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc private func toggleAutomaticUpdates() {
        updates.controller.updater.automaticallyDownloadsUpdates.toggle()
    }

    /// Turning it on puts the speakers at their safe level; turning it off leaves
    /// both volumes where they are, so nothing gets louder.
    @objc private func toggleOneVolume() {
        Settings.oneVolumeControl.toggle()
        if Settings.oneVolumeControl {
            for display in displays where display.supports(.speakerVolume) {
                display.set(.speakerVolume, normalized: display.speakerBase)
            }
        }
        refreshControls()
    }

    @objc private func toggleNightDimming() {
        Settings.nightDimming.toggle()
        nightMode.reset()
    }

    @objc private func selectSchedule(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let schedule = NightSchedule(storageValue: value) else { return }
        Settings.nightSchedule = schedule
        nightMode.reset()
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let (displayID, code) = sender.representedObject as? (CGDirectDisplayID, UInt8),
              let display = display(displayID),
              code != display.currentInput else { return }
        let alert = NSAlert()
        alert.messageText = "Switch \(display.name) to \(MCCS.Input(code: code).name)?"
        alert.informativeText = "The monitor will show that input instead of this Mac. Hush usually can't switch it back from here, so you may need the monitor's own buttons to return."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        display.switchInput(to: code)
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        audio.select(AudioObjectID(sender.tag))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("login item error \(error)")
        }
    }

    @objc private func openAccessibility() {
        MediaKeys.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu item builders

    private func header(_ text: String) -> NSMenuItem {
        note(text, font: .boldSystemFont(ofSize: NSFont.systemFontSize))
    }

    private func caption(_ text: String) -> NSMenuItem {
        note(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
    }

    private func note(_ text: String, font: NSFont? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let font { item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font]) }
        return item
    }

    private func sliderItem(_ slider: ModuleSlider) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: ModuleSlider.height + 10))
        slider.frame.origin = NSPoint(x: 16, y: 5)
        container.addSubview(slider)
        let item = NSMenuItem()
        item.view = container
        return item
    }
}
