// Installs, updates and removes the audio driver that ships inside the app
// (Contents/PlugIns/Hush.driver), so nobody has to open Terminal.
// macOS shows its own password dialog for the admin step.
//
// SPDX-License-Identifier: MIT

import AppKit

enum DriverInstaller {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Hush.driver")
    static var bundledURL: URL? {
        let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("Hush.driver")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// True when the driver is missing or its version differs from the one inside this app.
    /// Versions, not bytes: every build re-signs the binary, so its bytes always change.
    static var needsInstall: Bool {
        guard let bundled = bundledURL, let mine = version(of: bundled) else { return false }
        return version(of: installedURL) != mine
    }

    /// Reads Info.plist directly: Bundle caches by identifier, and the bundled and
    /// installed drivers share one, so Bundle(url:) can return nothing for the second.
    private static func version(of driver: URL) -> String? {
        let plist = driver.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleVersion"]) as? String
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Copies the bundled driver into HAL and restarts CoreAudio. False if cancelled or failed.
    static func install() -> Bool {
        guard let bundled = bundledURL else { return false }
        let dst = quoted(installedURL.path)
        return runAsAdmin("rm -rf \(dst) && ditto \(quoted(bundled.path)) \(dst) && chown -R root:wheel \(dst) && (killall -9 coreaudiod || true)",
                          prompt: "Hush needs to install its audio driver.")
    }

    static func uninstall() -> Bool {
        runAsAdmin("rm -rf \(quoted(installedURL.path)) && (killall -9 coreaudiod || true)",
                   prompt: "Hush needs to remove its audio driver.")
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String, prompt: String) -> Bool {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.info("driver admin step failed: \(error)"); return false }
        return true
    }
}
