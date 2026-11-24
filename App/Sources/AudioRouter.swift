// Decides when the Mac plays through the Hush driver, and on which device the
// driver plays.
//
// Policy: whenever the Mac's output is a device macOS can't change the volume
// of (HDMI, DisplayPort…), Hush becomes the system output and the driver
// plays on that device (the "target"). Devices with their own volume
// (speakers, AirPods…) are left alone.
//
// When the target goes away without the user choosing another one (the display
// sleeps or is unplugged), audio falls back to a real output and Hush takes
// the device again as soon as it returns.
//
// The driver is asked through its custom "target" property and answers every
// request with a change notification, so only one request is in flight.
//
// SPDX-License-Identifier: MIT

import CoreAudio
import Foundation

final class AudioRouter {
    static let hushUID = "HushDevice_UID"
    private static let savedTargetKey = "targetDeviceUID"
    private static let savedVolumeKey = "volume"
    /// The driver's custom property: UID of the device it plays on ("" = none).
    private static let targetProperty = CA.address(0x6D74_6774) // 'mtgt'

    /// The device the driver confirmed it is playing on.
    private(set) var target: AudioObjectID?
    /// UID asked of the driver and not answered yet ("" = stop playing).
    private var pending: String?
    /// UID the driver could not play on; not asked again until the devices change.
    private var refused: String?
    /// Retries already spent on the awaited device; HDMI can refuse IO for a moment after it returns.
    private var retries = 0
    private static let maxRetries = 5 // 1+2+4+8+16 s
    /// UID of the device we left only because it disappeared, and the output used meanwhile.
    private var awaitedUID: String?
    private var fallback: AudioObjectID = 0

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var hushListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenedHush: AudioObjectID = 0

    /// Between start() and stop(). Outside it the router leaves the driver and
    /// the system output alone: during a driver update the next instance of the
    /// app is already talking to the driver while this one is still quitting.
    private var running = false

    var onChange: (() -> Void)?

    var hush: AudioObjectID? { CA.device(withUID: Self.hushUID) }
    var driverInstalled: Bool { hush != nil }
    var isAwaitingTarget: Bool { awaitedUID != nil }

    // MARK: Lifecycle

    func start() {
        running = true
        let sys = CA.system
        func listen(_ selector: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
            listeners.append((sys, CA.address(selector), CA.listen(sys, CA.address(selector), block)))
        }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.evaluate() }
        listen(kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() }
        listen(kAudioHardwarePropertyServiceRestarted) { [weak self] in
            // A new coreaudiod: the driver plays on nothing and owes no answer.
            self?.target = nil
            self?.pending = nil
            self?.devicesChanged()
        }
        attachHushListeners()
        // Whatever a previous run left the driver doing, start from "none".
        // Its answer runs the policy.
        target = nil
        if !request("") { evaluate() }
    }

    /// Stop the driver's playback and restore the real device as system output.
    func stop() {
        guard running else { return }
        running = false
        for (obj, addr, l) in listeners { CA.unlisten(obj, addr, l) }
        listeners.removeAll()
        let restoreTo = target
        target = nil
        pending = nil
        if let hush {
            CA.set(hush, Self.targetProperty, "" as CFString)
            if CA.defaultOutput == hush, let restoreTo { CA.setDefaultOutput(restoreTo) }
        }
    }

    // MARK: Driver

    /// Asks the driver to play on the device with that UID ("" = stop).
    /// False if the driver can't be asked (missing, or older than this app).
    private func request(_ uid: String) -> Bool {
        guard let hush, CA.set(hush, Self.targetProperty, uid as CFString) == noErr else { return false }
        pending = uid
        return true
    }

    private func ask(_ dev: AudioObjectID) -> Bool {
        guard let hush, let uid = CA.uid(dev) else { return false }
        // Run Hush at the target's sample rate so no conversion is needed.
        var rate = CA.nominalRate(dev)
        if !CA.availableRates(hush).contains(rate) {
            rate = 48000
            if CA.availableRates(dev).contains(rate) {
                CA.set(dev, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
            }
        }
        CA.set(hush, CA.address(kAudioDevicePropertyNominalSampleRate), rate)
        if request(uid) { return true }
        refused = uid
        return false
    }

    private func driverAnswered() {
        guard let asked = pending, let hush else { return }
        pending = nil
        let playing = CA.string(hush, Self.targetProperty.mSelector) ?? ""
        if playing == asked {
            target = asked.isEmpty ? nil : CA.device(withUID: asked)
            if target != nil {
                retries = 0
                UserDefaults.standard.set(asked, forKey: Self.savedTargetKey)
            }
        } else {
            Log.info("the driver could not play on \(asked)")
            refused = asked
            if asked == awaitedUID { retryAwaited(asked) }
        }
        evaluate()
    }

    /// The display that came back refused IO (it often does for a moment after
    /// waking): ask again a few times instead of staying on the fallback.
    private func retryAwaited(_ uid: String) {
        guard retries < Self.maxRetries else { return }
        let delay = Double(1 << retries)
        retries += 1
        Log.info("retrying \(uid) in \(Int(delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.refused == uid, self.awaitedUID == uid else { return }
            self.refused = nil
            self.evaluate()
        }
    }

    private func clearTarget() {
        guard target != nil else { return }
        target = nil
        _ = request("")
    }

    // MARK: Policy

    private func devicesChanged() {
        if let t = target, !CA.allDevices().contains(t) { clearTarget() }
        refused = nil
        retries = 0
        evaluate()
    }

    func evaluate() {
        attachHushListeners()
        if running, pending == nil { applyPolicy() } // otherwise the driver's answer runs it
        onChange?()
    }

    private func usable(_ uid: String?) -> AudioObjectID? {
        guard let uid, uid != refused, let dev = CA.device(withUID: uid), CA.hasOutput(dev) else { return nil }
        return dev
    }

    private func applyPolicy() {
        guard let hush else { target = nil; return }

        if let dev = usable(awaitedUID) {
            // The display is back.
            if target == dev {
                awaitedUID = nil
                CA.setDefaultOutput(hush)
            } else {
                _ = ask(dev)
            }
            return
        }

        let current = CA.defaultOutput
        if current == hush {
            guard target == nil else { return }
            // On Hush with nowhere to play: the target vanished, or we were relaunched.
            let uid = UserDefaults.standard.string(forKey: Self.savedTargetKey)
            if let dev = usable(uid), ask(dev) { return }
            awaitedUID = uid
            // Prefer an output with its own volume. Never the awaited device itself
            // (still listed while it refuses IO after a wake): it would play at
            // full level with Hush out of the way, and end the wait.
            let outputs = outputDevices()
            fallback = outputs.first(where: CA.hasSettableVolume) ?? outputs.first { CA.uid($0) != uid } ?? 0
            if fallback != 0 { CA.setDefaultOutput(fallback) }
        } else if current != 0, !CA.hasSettableVolume(current), CA.hasOutput(current) {
            // A fixed-volume output (HDMI…) was selected: put Hush in front of it.
            awaitedUID = nil
            if target == current {
                CA.setDefaultOutput(hush)
            } else if CA.uid(current) != refused {
                _ = ask(current)
            }
        } else {
            // A device with its own volume: get out of the way. Unless it is our
            // own fallback, the user chose it, so stop waiting for the display.
            if current != fallback { awaitedUID = nil }
            clearTarget()
        }
    }

    /// Real output devices the user can choose from (Hush hidden).
    func outputDevices() -> [AudioObjectID] {
        CA.allDevices().filter { CA.hasOutput($0) && CA.uid($0) != Self.hushUID }
    }

    /// User picked a device in our menu.
    func select(_ dev: AudioObjectID) {
        awaitedUID = nil
        refused = nil
        CA.setDefaultOutput(dev) // the default-output listener runs evaluate()
    }

    // MARK: Volume (Hush's own control)

    var volume: Float {
        get {
            guard let hush else { return 0 }
            return CA.get(hush, CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), Float32(0)) ?? 0
        }
        set {
            guard let hush else { return }
            CA.set(hush, CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), Float32(max(0, min(1, newValue))))
        }
    }

    var muted: Bool {
        get {
            guard let hush else { return false }
            return (CA.get(hush, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0) != 0
        }
        set {
            guard let hush else { return }
            CA.set(hush, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(newValue ? 1 : 0))
        }
    }

    /// True while the Mac is actually playing through Hush.
    var isActiveOutput: Bool {
        guard let hush else { return false }
        return CA.defaultOutput == hush
    }

    /// Follows the Hush device (its ID changes when the driver is reinstalled).
    private func attachHushListeners() {
        let current = hush ?? 0
        guard current != listenedHush else { return }
        for (addr, l) in hushListeners { CA.unlisten(listenedHush, addr, l) }
        hushListeners.removeAll()
        listenedHush = current
        guard current != 0 else { return }
        // A new device (launch, reboot, CoreAudio restart) starts at whatever
        // CoreAudio picks, often 100%: put back the last volume the user set.
        if let saved = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Float { self.volume = saved }
        let volumeAddress = CA.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        hushListeners.append((volumeAddress, CA.listen(current, volumeAddress) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.volume, forKey: Self.savedVolumeKey)
            self.onChange?()
        }))
        hushListeners.append((Self.targetProperty, CA.listen(current, Self.targetProperty) { [weak self] in self?.driverAnswered() }))
    }
}
