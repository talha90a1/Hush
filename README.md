<p align="center"><img src="docs/icon.png" width="128" alt="Hush icon"></p>

# Hush

A real volume control and working brightness keys for HDMI and DisplayPort monitors on the Mac.

Based on [Mando](https://github.com/Aliasviejo/Mando) by Aliasviejo. MIT licensed.

## Why

Over HDMI, DisplayPort or USB-C, macOS sends audio to a monitor at full level and leaves the volume to the monitor. The volume keys show a crossed-out speaker. On some monitors, such as the Dell S2725QC, even the lowest hardware step is too loud, and apps that set the monitor's volume over DDC stop at that same minimum. The brightness keys do nothing on most third-party monitors either.

## Features

- **Volume down to silent.** A small virtual audio device sits in front of the monitor and scales the audio, so the volume keys, Control Center and the menu slider work.
- **One volume control.** The lower 75% of the scale is Hush's volume, with the monitor's speakers held at a safe level (25% by default). The top 25% raises the monitor's own speakers. On quit the speakers go back to the safe level.
- **Brightness keys** change the monitor's backlight over DDC/CI. <kbd>⇧</kbd><kbd>⌥</kbd> gives finer steps.
- **Dimmer than the monitor allows**, with an overlay below the lowest backlight level.
- **Night dimming** from sunset to sunrise, or fixed hours. Hush remembers the brightness you pick by day and at night. The location comes from your time zone, so no Location permission is needed.
- **Monitor controls:** contrast, speaker level and input switching, for the controls your monitor reports.
- **Several monitors.** The brightness keys act on the screen under the pointer.
- **Automatic updates** through [Sparkle](https://sparkle-project.org).

Each of these can be turned off in **Settings**.

## Install

Requires macOS 14 or later. DDC brightness needs Apple silicon and DDC/CI turned on in the monitor's menu.

1. Download `Hush-x.y.z.dmg` from [Releases](https://github.com/talha90a1/Hush/releases/latest) and drag Hush to Applications.
2. Open Hush. Releases aren't notarized by Apple, so macOS blocks the first launch: go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Click **Install** when Hush offers to install its audio driver, and enter your password.
4. Allow **Accessibility** for Hush when asked. It's needed for the volume and brightness keys.

Hush checks for updates once a day. Use **Check for Updates…** in the menu to check now, or turn on **Settings → Install Updates Automatically**.

To remove Hush, choose **Uninstall Hush…** from its menu.

## Keyboards

Hush handles the keys macOS already treats as volume and brightness, so no keyboard software is needed. On PC-layout keyboards, <kbd>Scroll Lock</kbd> and <kbd>Pause</kbd> (F14 and F15) change the brightness. If F1–F12 act as function keys, hold <kbd>Fn</kbd>.

## Privacy

Hush records nothing: the driver has no input side and needs no microphone permission. Its only network access is the daily update check against this repository's releases.

## Building

Requires the Xcode 26 command line tools.

```bash
./scripts/build.sh     # build.noindex/Hush.app, ad-hoc signed
./scripts/test.sh      # tests, no monitor needed
./scripts/install.sh   # build, then install the driver and the app
```

Set `SIGN_ID` to a code-signing identity in your keychain to keep the Accessibility permission across rebuilds.

Releases are built by GitHub Actions when a `v*` tag is pushed: [`.github/workflows/release.yml`](.github/workflows/release.yml) signs the app, packs the DMG and publishes it with the Sparkle appcast.

## How it works

```
apps ──▶ Hush (virtual device, volume applied) ──▶ monitor
```

- `Driver/HushDriver.c`: a CoreAudio AudioServerPlugIn that publishes an output device with volume and mute, scales the mix and plays it on the monitor, keeping its clock in step with the monitor's.
- `App/Sources/AudioRouter.swift`: puts Hush in front of fixed-volume outputs and tells the driver where to play.
- `App/Sources/DDC.swift`: DDC/CI through `IOAVService`. `DisplayPairing.swift` matches each DDC service to its screen.
- `App/Sources/MediaKeys.swift`: the event tap for the media keys.

## Credits

- [Mando](https://github.com/Aliasviejo/Mando) by Aliasviejo (MIT). Hush is a fork; the driver, routing, DDC and media-key code come from it, and its history is kept here.
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT), for documenting DDC on Apple silicon.
- [Solar](https://github.com/ceeK/Solar) by Chris Howell (MIT), for sunrise and sunset times, vendored in `App/Sources/Solar.swift`.
- [Sparkle](https://sparkle-project.org) (MIT), for updates.
- [OpenDisplay](https://github.com/aquitaine/OpenDisplay) (GPL-3.0), for ideas only; no code was copied.

## License

MIT. See [LICENSE](LICENSE).
