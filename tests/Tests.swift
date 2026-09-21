//
// The checks. A plain executable rather than XCTest: the whole project builds
// with swiftc and nothing else, and a test runner is not worth breaking that
// for.
//
// Every suite is handed the same `check` closure so the failure count stays in
// one place, and every suite is logic only -- no window is created, so this runs
// on a headless runner.
//

import AppKit

/// A sample built to order. Defaults describe an ordinary application process:
/// owned by the user, with a path, not a zombie, not a GUI app, and with
/// nothing known about its windows or whether it is answering -- which is what
/// every process looks like until the app is granted Accessibility.
func testProc(pid: pid_t, ppid: pid_t = 100, cpu: Double = 0, memMB: Double = 100,
              ageH: Double = 1, writeKBs: Double = 0, wakeups: Double = 0,
              path: String = "/Applications/X.app/Contents/MacOS/X",
              started: UInt64 = 1, zombie: Bool = false, gui: Bool = false,
              windows: Int? = nil, responsive: Bool? = nil) -> ProcSample {
    ProcSample(pid: pid, ppid: ppid,
               name: path.isEmpty ? "x" : (path as NSString).lastPathComponent,
               path: path, cpu: cpu, memory: UInt64(memMB * 1_048_576),
               age: ageH * 3600, startedMicros: started, writeRate: writeKBs * 1024,
               readRate: 0, wakeupRate: wakeups, isZombie: zombie,
               isGUIApp: gui, windows: windows, responsive: responsive)
}

/// A defaults domain of its own, so checking persistence cannot disturb the
/// settings of the app installed on this machine.
func testDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: "com.local.reaper.tests")!
    d.removePersistentDomain(forName: "com.local.reaper.tests")
    return d
}

@main
enum Tests {
    static func main() {
        // AppKit wants an application instance before NSColor will behave, even
        // with nothing on screen.
        _ = NSApplication.shared

        var ran = 0, failed = 0
        let check: (Bool, String, String) -> Void = { ok, what, detail in
            ran += 1
            if ok {
                print("  ok   \(what)")
            } else {
                failed += 1
                print("  FAIL \(what)  \(detail)")
            }
        }

        print("rules")
        RuleTests.run(check)
        print("watch")
        WatchTests.run(check)
        print("views")
        ViewTests.run(check)
        print("diagnostics")
        DiagnosticsTests.run(check)
        print("history")
        HistoryTests.run(check)

        UserDefaults().removePersistentDomain(forName: "com.local.reaper.tests")
        print("\(ran) checks, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
