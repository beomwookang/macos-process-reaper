//
// Shared odds and ends: the app's identity, how it runs a command, how it
// becomes a login item, and how it prints a number.
//
// Split out from main.swift so the model and the windows can be linked into the
// test binary: main.swift carries top-level code, which Swift only allows in a
// file of that name, and which therefore cannot be linked into anything else.
//

import AppKit
import Foundation

let APP_NAME    = "Reaper"
let BUNDLE_ID   = "com.local.reaper"
let AGENT_LABEL = "com.local.reaper"

// MARK: - subprocess

/// Runs a command and collects what it said. Only ever used for launchctl and
/// open: this app has no helper binary and nothing it does needs a shell.
@discardableResult
func shell(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (-1, "") }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = (String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? "")
    return (p.terminationStatus, text)
}

// MARK: - login item

/// A LaunchAgent rather than SMAppService: this bundle is ad-hoc signed, and a
/// plist in ~/Library/LaunchAgents works the same on every macOS without
/// needing a Developer ID.
enum LoginItem {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(AGENT_LABEL).plist"
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func set(_ on: Bool, appPath: String) {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let uid = getuid()
        if on {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(AGENT_LABEL)</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        } else {
            shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(AGENT_LABEL)"])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - load colour

/// Colour for a CPU figure, in percent of one core as top counts it.
///
/// Two steps above normal, no gradient. A gradient would be prettier and would
/// say less: what a glance needs to answer is "is this idle, working, or running
/// away", and three answers need three colours.
func loadColor(_ cpu: Double, quiet: Bool = false) -> NSColor {
    if cpu >= 300 { return .systemRed }
    if cpu >= 100 { return .systemOrange }
    return quiet ? .secondaryLabelColor : .labelColor
}

// MARK: - formatting

func fmtNum(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%.1f", d)
}

func fmtBytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1_048_576
    if mb < 1000 { return String(format: "%.0f MB", mb) }
    return String(format: "%.1f GB", mb / 1024)
}

/// Ages read the way `ps` prints them, at the precision that matters at each
/// scale: seconds under a minute, minutes under an hour, then hours and
/// minutes, then days and hours.
func fmtAge(_ s: TimeInterval) -> String {
    let t = Int(s.rounded())
    if t < 60 { return "\(t) s" }
    if t < 3600 { return "\(t / 60) min" }
    if t < 86400 { return "\(t / 3600) h \(t % 3600 / 60) m" }
    return "\(t / 86400) d \(t % 86400 / 3600) h"
}

func fmtCPU(_ c: Double) -> String { String(format: "%.0f%%", c) }

/// A wall-clock instant, for the one place that shows when a process started
/// rather than how long ago that was.
func fmtWhen(_ epoch: TimeInterval) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: epoch))
}
