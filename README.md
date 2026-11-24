<p align="center"><img src="docs/icon.png" width="128" alt="Hush icon"></p>

# Hush

**A real volume control and working brightness keys for HDMI and DisplayPort monitors on your Mac.**

Free and open source (MIT). Based on [Mando](https://github.com/Aliasviejo/Mando) by Aliasviejo, translated to English and extended.

## The problem

When a Mac sends audio to a monitor over HDMI, DisplayPort or USB-C, macOS treats it as a fixed-volume output. It sends a full-level digital signal and leaves the volume entirely to the monitor. The volume keys show a crossed-out speaker, and the only control left is the monitor's own volume.

On some monitors (for example the Dell S2725QC) even the lowest hardware volume step is too loud, so notification sounds and videos are uncomfortable, especially at night. Apps that change the monitor's volume over DDC (MonitorControl, Dell Display and Peripheral Manager) can't help, because they stop at the same hardware minimum.

The brightness keys also do nothing on most third-party monitors.

## What Hush does

- **Volume, the Mac way.** Hush installs a small virtual audio device with a real volume and mute control. Audio passes through it, gets attenuated in software, and goes on to your monitor. The volume keys, the menu bar slider and the macOS volume indicator all work, and you can go all the way down to silent.
- **The monitor's volume becomes the ceiling.** Set the monitor's own volume once (for example 20–30) and leave it; Hush handles everything below it.
- **Brightness over DDC/CI.** The brightness keys change the monitor's real backlight and show the macOS brightness indicator. Hold <kbd>⇧</kbd><kbd>⌥</kbd> for finer steps (also for volume).
- **Automatic.** Pick your monitor as the output and Hush wraps it. Pick speakers, headphones or AirPods (devices that already have volume) and Hush gets out of the way.
- **Menu bar.** Volume and brightness sliders and an output picker. Opens at login (you can turn that off).
- **No microphone permission.** The driver plays straight to the monitor inside CoreAudio; nothing is recorded and the app has no network access.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon recommended (DDC brightness uses Apple Silicon display services). The audio part also works on Intel.
- Brightness needs DDC/CI turned on in the monitor's menu (usually the default).

## Install

Hush is built from source for now (there are no signed releases yet). You need Xcode or the Command Line Tools.

```bash
git clone https://github.com/talha90a1/Hush.git
cd Hush
./scripts/install.sh
```

`install.sh` builds the app, installs the audio driver to `/Library/Audio/Plug-Ins/HAL` (macOS asks for your password), copies Hush to `/Applications` and opens it. Then:

1. Allow **Accessibility** for Hush when macOS asks (needed for the volume and brightness keys).
2. Choose your monitor in Hush's **Sound Output** menu, or in System Settings → Sound.
3. Set the monitor's own volume to a comfortable maximum and use the Mac's volume keys from then on.

To remove everything: use **Uninstall Hush…** in the menu, or run `./scripts/uninstall.sh`.

## Keyboards

Hush reads the keys macOS already knows as volume and brightness, so it needs no keyboard software.

- **Apple keyboards** and **Logitech keyboards with Mac layout** (MX Keys, MX Mechanical, K380…): the keys work as printed.
- **PC-layout keyboards**: <kbd>Scroll Lock</kbd> and <kbd>Pause</kbd> (F14/F15 on a Mac) change the brightness, like on macOS itself.
- If F1–F12 are set to act as standard function keys, hold <kbd>Fn</kbd>.

## FAQ

**Why can't I change the volume on my HDMI or DisplayPort monitor from my Mac?**
macOS sends digital audio over HDMI/DisplayPort at a fixed level and leaves volume to the monitor. Hush puts a virtual device with its own volume control in front of the monitor.

**My monitor is too loud even at volume 1. Does Hush fix that?**
Yes. Hush lowers the signal before it reaches the monitor, so you get the full range below the monitor's minimum.

**Does it change the sound quality?**
At 100% the audio passes through unchanged. Below that it is scaled in 32-bit float, so there is no audible loss.

## Build from source

```bash
./scripts/build.sh                                   # ad-hoc signed
SIGN_ID="Apple Development: …" ./scripts/build.sh    # signed with a certificate in your keychain
```

A stable signature (not ad-hoc) keeps the Accessibility permission across rebuilds.

The driver's playback and clock logic has a test that runs in simulated time:

```bash
mkdir -p build && clang -O2 -framework CoreFoundation -framework CoreAudio tests/forwarding_test.c -o build/forwarding_test && build/forwarding_test
```

## How it works

```
apps ──▶ Hush (virtual device, volume applied) ──▶ HDMI / DisplayPort monitor
                          ▲                    ▲
                volume keys / macOS         Hush.app chooses the monitor
```

- `Driver/HushDriver.c` is a CoreAudio AudioServerPlugIn. It publishes an output device with volume and mute, applies the gain to the mix and plays the result on the monitor, keeping its clock in step with the monitor's. It has no input side, so nothing records.
- `App/Sources/AudioRouter.swift` makes Hush the system output when the Mac plays on a fixed-volume device and tells the driver which device to play on.
- `App/Sources/DDC.swift` talks DDC/CI (VESA MCCS, VCP `0x10`) through `IOAVService`.
- `App/Sources/MediaKeys.swift` is a `CGEventTap` that handles the media keys.

## Credits

- **[Mando](https://github.com/Aliasviejo/Mando)** by Aliasviejo (MIT): Hush is a fork of Mando. The audio driver, routing, DDC and media-key code all come from it; its full commit history is kept in this repository.
- **[MonitorControl](https://github.com/MonitorControl/MonitorControl)** (MIT): documented DDC on Apple Silicon, which Mando's DDC code builds on.

## License

MIT. See [LICENSE](LICENSE). The original Mando copyright notice is kept, as the license requires.
