//
// Checks for the sampler: the sustain clock, what may be killed, the traces the
// detail window draws, and the formatting every row relies on.
//
// The tracker's evaluate() takes `now` as a parameter precisely so the clock can
// be driven here: a five-minute sustain is checked in five lines, not five
// minutes. The live samples at the end are smoke tests only -- what they find
// depends on the machine.
//

import ApplicationServices
import Foundation

enum WatchTests {
    static func run(_ check: (Bool, String, String) -> Void) {
        sustain(check)
        holding(check)
        identity(check)
        killing(check)
        formatting(check)
        live(check)
    }

    private static let runaway = WatchRule(name: "Runaway", minCPU: 300, sustain: 300)
    private static let quick = WatchRule(name: "quick", minCPU: 100)

    // MARK: - the sustain clock

    private static func sustain(_ check: (Bool, String, String) -> Void) {
        let tr = ProcTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        var v = tr.evaluate([testProc(pid: 7, cpu: 900)], rules: [runaway], now: t0)
        check(v.flagged.isEmpty, "sustain: not flagged on first sight", "\(v.flagged.count)")
        v = tr.evaluate([testProc(pid: 7, cpu: 900)], rules: [runaway], now: t0 + 299)
        check(v.flagged.isEmpty, "sustain: not flagged just before the duration", "\(v.flagged.count)")
        v = tr.evaluate([testProc(pid: 7, cpu: 900)], rules: [runaway], now: t0 + 300)
        check(v.flagged.count == 1 && v.flagged.first?.proc.pid == 7,
              "sustain: flagged once the duration has held", "\(v.flagged.count)")
        check(abs((v.flagged.first?.heldFor ?? 0) - 300) < 0.01,
              "heldFor reports how long it has held", "\(v.flagged.first?.heldFor ?? -1)")

        v = tr.evaluate([testProc(pid: 7, cpu: 10)], rules: [runaway], now: t0 + 301)
        check(v.flagged.isEmpty && v.holding.isEmpty,
              "a dip below the threshold clears the flag", "\(v.flagged.count)")
        v = tr.evaluate([testProc(pid: 7, cpu: 900)], rules: [runaway], now: t0 + 302)
        check(v.flagged.isEmpty, "...and restarts the clock", "\(v.flagged.count)")

        var off = runaway
        off.enabled = false
        let tr2 = ProcTracker()
        _ = tr2.evaluate([testProc(pid: 9, cpu: 900)], rules: [off], now: t0)
        v = tr2.evaluate([testProc(pid: 9, cpu: 900)], rules: [off], now: t0 + 1000)
        check(v.flagged.isEmpty && v.holding.isEmpty, "a disabled rule flags nothing", "\(v.flagged.count)")

        let mem = WatchRule(name: "mem", minMemoryMB: 4096)
        v = tr2.evaluate([testProc(pid: 10, memMB: 5000)], rules: [mem], now: t0)
        check(v.flagged.count == 1, "a zero sustain flags on first sight", "\(v.flagged.count)")

        // One entry per process, from the first rule that has held long enough;
        // the list comes back busiest first.
        v = tr2.evaluate([testProc(pid: 11, cpu: 500), testProc(pid: 12, cpu: 800)],
                         rules: [runaway, quick], now: t0)
        check(v.flagged.count == 2, "one flag per process even when two rules could apply",
              "\(v.flagged.count)")
        check(v.flagged.allSatisfy { $0.rule.name == "quick" },
              "the rule that has held long enough wins over one still counting",
              "\(v.flagged.map { $0.rule.name })")
        check(v.flagged.map { $0.proc.pid } == [12, 11], "flags come back busiest first",
              "\(v.flagged.map { $0.proc.pid })")

        // reset(rule:) restarts that rule's clock and no other's.
        let tr3 = ProcTracker()
        _ = tr3.evaluate([testProc(pid: 13, cpu: 900)], rules: [runaway, quick], now: t0)
        tr3.reset(rule: runaway.id)
        v = tr3.evaluate([testProc(pid: 13, cpu: 900)], rules: [runaway], now: t0 + 300)
        check(v.flagged.isEmpty, "reset(rule:) restarts that rule's clock", "\(v.flagged.count)")
        v = tr3.evaluate([testProc(pid: 13, cpu: 900)], rules: [quick], now: t0 + 300)
        check(v.flagged.count == 1, "reset(rule:) leaves other rules' clocks alone", "\(v.flagged.count)")

        // resetAll is what picking a profile does: the new rules have not held
        // for any time yet, whatever the old ones had accumulated.
        let tr4 = ProcTracker()
        _ = tr4.evaluate([testProc(pid: 14, cpu: 900)], rules: [runaway], now: t0)
        tr4.resetAll()
        v = tr4.evaluate([testProc(pid: 14, cpu: 900)], rules: [runaway], now: t0 + 299)
        check(v.flagged.isEmpty, "resetAll restarts every clock", "\(v.flagged.count)")
    }

    // MARK: - holding

    private static func holding(_ check: (Bool, String, String) -> Void) {
        let tr = ProcTracker()
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        var v = tr.evaluate([testProc(pid: 20, cpu: 900)], rules: [runaway], now: t0)
        check(v.holding.count == 1 && v.holding.first?.sustained == false,
              "a process whose rule holds but not long enough is reported as holding, not flagged",
              "\(v.holding.count)")
        check(v.holding.first?.progress == 0,
              "holding starts at no progress", "\(v.holding.first?.progress ?? -1)")

        v = tr.evaluate([testProc(pid: 20, cpu: 900)], rules: [runaway], now: t0 + 150)
        check(abs((v.holding.first?.progress ?? 0) - 0.5) < 0.01,
              "progress is how far through the sustain it is", "\(v.holding.first?.progress ?? -1)")

        v = tr.evaluate([testProc(pid: 20, cpu: 900)], rules: [runaway], now: t0 + 300)
        check(v.flagged.count == 1 && v.holding.isEmpty,
              "once sustained it is flagged and no longer holding", "\(v.holding.count)")
        check(v.flagged.first?.progress == 1, "a flagged process is fully through its sustain", "")

        // With two rules counting, the one nearest to firing is the one
        // reported: it is the one about to matter.
        let slow = WatchRule(name: "slow", minCPU: 100, sustain: 1000)
        let fast = WatchRule(name: "fast", minCPU: 100, sustain: 100)
        let tr2 = ProcTracker()
        _ = tr2.evaluate([testProc(pid: 21, cpu: 200)], rules: [slow, fast], now: t0)
        v = tr2.evaluate([testProc(pid: 21, cpu: 200)], rules: [slow, fast], now: t0 + 50)
        check(v.holding.count == 1 && v.holding.first?.rule.name == "fast",
              "of two rules counting, the one nearest firing is reported",
              "\(v.holding.map { $0.rule.name })")

        // A rule with no sustain never holds: it flags outright.
        let tr3 = ProcTracker()
        v = tr3.evaluate([testProc(pid: 22, cpu: 200)], rules: [quick], now: t0)
        check(v.holding.isEmpty && v.flagged.count == 1,
              "a rule with no sustain flags rather than holds", "\(v.holding.count)")
    }

    // MARK: - identity

    private static func identity(_ check: (Bool, String, String) -> Void) {
        let tr = ProcTracker()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        _ = tr.evaluate([testProc(pid: 8, cpu: 900, started: 1)], rules: [runaway], now: t0)
        let v = tr.evaluate([testProc(pid: 8, cpu: 900, started: 2)], rules: [runaway], now: t0 + 600)
        check(v.flagged.isEmpty, "a reused pid does not inherit the old process's clock",
              "\(v.flagged.count)")

        // Start time is the identity, so it has to be readable back off a
        // sample in the units the kernel reports.
        let p = testProc(pid: 1, started: 1_700_000_000_500_000)
        check(abs(p.started - 1_700_000_000.5) < 0.001,
              "a sample's start time reads back as seconds since the epoch", "\(p.started)")
    }

    // MARK: - killing

    private static func killing(_ check: (Bool, String, String) -> Void) {
        check(killability(of: testProc(pid: 5)) == .yes,
              "an ordinary process may be killed", "")
        check(killability(of: testProc(pid: 5, path: "/usr/libexec/trustd")) == .system,
              "a system process is not offered", "")
        check(killability(of: testProc(pid: 5, ppid: 400, path: "", zombie: true))
                == .zombie(parent: 400),
              "a zombie is not signalled, and names its parent instead", "")
        check(killability(of: testProc(pid: 5, ppid: 1, path: "", zombie: true))
                == .zombie(parent: nil),
              "a zombie reparented to launchd has no parent worth ending", "")
        // Being a zombie is decided before being a system process: a dead
        // system process still cannot be signalled, and the reason that matters
        // is the one the button can act on.
        check(killability(of: testProc(pid: 5, ppid: 400, path: "/usr/libexec/trustd", zombie: true))
                == .zombie(parent: 400),
              "a zombie system process reports as a zombie", "")

        // What the row's button acts on.
        let ordinary = testProc(pid: 5)
        check(killTarget(ordinary, parent: nil)?.pid == 5,
              "an ordinary process is its own kill target", "")
        check(killTarget(testProc(pid: 5, path: "/usr/libexec/trustd"), parent: nil) == nil,
              "a system process is no target at all", "")
        let live = testProc(pid: 400)
        let zomb = testProc(pid: 5, ppid: 400, path: "", zombie: true)
        check(killTarget(zomb, parent: live)?.pid == 400,
              "a zombie's target is its parent, since only the parent clears it", "")
        check(killTarget(zomb, parent: nil) == nil,
              "a zombie whose parent was not sampled has no target", "")
        check(killTarget(zomb, parent: testProc(pid: 400, path: "", zombie: true)) == nil,
              "a zombie parented by another zombie has no target", "")
        check(killTarget(zomb, parent: testProc(pid: 400, path: "/usr/libexec/trustd")) == nil,
              "a zombie parented by macOS is a dead end, not a system process to kill", "")

        check(testProc(pid: 1, path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow").isSystem,
              "loginwindow is system", "")
        check(testProc(pid: 1, path: "/usr/libexec/trustd").isSystem, "/usr/libexec is system", "")
        check(!testProc(pid: 1, path: "/usr/local/bin/node").isSystem, "/usr/local is not system", "")
        check(!testProc(pid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").isSystem,
              "an app is not system", "")
        check(!testProc(pid: 1, path: "").isSystem, "an unknown path is not assumed system", "")
    }

    // MARK: - formatting

    private static func formatting(_ check: (Bool, String, String) -> Void) {
        check(fmtBytes(487 * 1_048_576) == "487 MB", "fmtBytes: megabytes", fmtBytes(487 * 1_048_576))
        check(fmtBytes(1_400_000_000) == "1.3 GB", "fmtBytes: gigabytes", fmtBytes(1_400_000_000))
        check(fmtAge(42) == "42 s", "fmtAge: seconds", fmtAge(42))
        check(fmtAge(5 * 60 + 12) == "5 min", "fmtAge: minutes", fmtAge(5 * 60 + 12))
        check(fmtAge(21 * 3600 + 37 * 60) == "21 h 37 m", "fmtAge: hours and minutes",
              fmtAge(21 * 3600 + 37 * 60))
        check(fmtAge(3 * 86400 + 2 * 3600) == "3 d 2 h", "fmtAge: days and hours",
              fmtAge(3 * 86400 + 2 * 3600))
        check(fmtCPU(812.4) == "812%", "fmtCPU", fmtCPU(812.4))
        check(fmtNum(300) == "300" && fmtNum(0.5) == "0.5", "fmtNum drops a pointless decimal",
              fmtNum(300) + " " + fmtNum(0.5))
    }

    // MARK: - one live pass: does the plumbing work on this machine

    private static func live(_ check: (Bool, String, String) -> Void) {
        let tr = ProcTracker()
        let first = tr.sample()
        check(!first.isEmpty, "sample() sees this user's processes", "\(first.count)")
        check(!first.contains { $0.pid == getpid() },
              "sample() leaves out the sampling process itself", "")
        check(first.allSatisfy { $0.cpu == 0 }, "first sample has no CPU figure yet", "")
        check(first.allSatisfy { $0.age >= 0 && $0.startedMicros > 0 },
              "ages and start times are sane", "")
        check(first.allSatisfy { $0.isZombie || $0.memory > 0 },
              "every live process has a footprint, and no zombie is expected to", "")
        check(first.allSatisfy { $0.responsive == nil },
              "nothing reads as responsive when no context was handed in", "")
        check(first.allSatisfy { $0.windows == nil },
              "nothing reads as windowless when no context was handed in", "")

        let second = tr.sample()
        check(second.allSatisfy { $0.cpu >= 0 }, "second sample's CPU figures are non-negative", "")
        if let p = second.first {
            check(!tr.traceFor(p.pid).isEmpty, "a trace is kept for a sampled process", "")
            check(tr.traceFor(-1).isEmpty, "no trace is invented for a pid never seen", "")
        }

        // The real thing must still be the thing that was listed.
        if let mine = second.first(where: { $0.pid == getppid() }) {
            check(tr.stillAlive(mine), "stillAlive agrees about a process that is still there", "")
            let moved = ProcSample(pid: mine.pid, ppid: mine.ppid, name: mine.name,
                                   path: mine.path, cpu: mine.cpu, memory: mine.memory,
                                   age: mine.age, startedMicros: mine.startedMicros + 1)
            check(!tr.stillAlive(moved),
                  "stillAlive rejects a pid whose start time has changed under it", "")
        }

        let args = procArgs(getpid())
        check(!args.isEmpty && args[0].hasSuffix("tests"), "procArgs returns this process's own argv",
              "\(args)")
        check((threadCount(getpid()) ?? 0) > 0, "threadCount reports this process's threads",
              "\(threadCount(getpid()) ?? -1)")
        check((fdCount(getpid()) ?? 0) > 0, "fdCount reports this process's open descriptors",
              "\(fdCount(getpid()) ?? -1)")

        let load = tr.systemLoad()
        check(load.ncpu > 0 && load.memTotal > 0 && load.memUsed > 0 && load.memUsed < load.memTotal,
              "systemLoad reports cores and memory", "\(load)")

        // The context gatherers must not crash, and must not claim a
        // capability they do not have. On a headless runner, and on any machine
        // that has granted nothing, both have to come back saying so rather
        // than failing.
        let gui = guiAppPIDs()
        let (ctx, cap) = liveContext(guiApps: gui, inspectApps: false)
        check(ctx.guiApps == gui, "the context carries the GUI apps it was given", "")
        check(ctx.probed.isEmpty && ctx.unresponsive.isEmpty && ctx.windows.isEmpty,
              "nothing is asked while the inspection switch is off", "")
        check(!cap.appsInspected && !cap.reason.isEmpty,
              "the inspection reports itself unavailable, with a reason", cap.reason)

        // Asking for it without the permission must report that, not silently
        // succeed and not silently probe.
        let (ctx2, cap2) = liveContext(guiApps: gui, inspectApps: true)
        if AXIsProcessTrusted() {
            check(cap2.appsInspected && ctx2.probed == gui && cap2.reason.isEmpty,
                  "with Accessibility granted, every GUI app is asked", "\(ctx2.probed.count)")
            check(ctx2.windows.keys.allSatisfy { ctx2.probed.contains($0) },
                  "a window count is only ever recorded for an app that was asked", "")
            check(ctx2.unresponsive.allSatisfy { ctx2.windows[$0] == nil },
                  "an app that did not answer has no window count either", "")
        } else {
            check(!cap2.appsInspected && ctx2.probed.isEmpty
                    && cap2.reason.contains("Accessibility"),
                  "without Accessibility, the inspection reports why rather than asking",
                  cap2.reason)
        }

        // The probe against this process: it is not an app, has no accessibility
        // port, and must come back as something other than a crash.
        let own = probeApp(getpid())
        check(own.responsive || own.windows == nil,
              "probing a process that is not an app does not crash or invent a window count",
              "\(own)")
    }
}
