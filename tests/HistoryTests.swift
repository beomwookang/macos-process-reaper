//
// Checks for the two things that make the app worth leaving switched on: the
// log of what was flagged, and the list of what is never to be flagged.
//
// The clock is a parameter throughout, so an event that lasted twenty minutes
// is checked in four lines.
//

import Foundation

enum HistoryTests {
    static func run(_ check: (Bool, String, String) -> Void) {
        newThresholds(check)
        windowCounts(check)
        exclusions(check)
        log(check)
        storage(check)
    }

    private static func flag(_ p: ProcSample, _ r: WatchRule, held: TimeInterval = 0)
        -> ProcTracker.Flag {
        ProcTracker.Flag(proc: p, rule: r, heldFor: held, sustained: true)
    }

    // MARK: - the two new conditions

    private static func newThresholds(_ check: (Bool, String, String) -> Void) {
        let noisy = WatchRule(name: "Writing hard", minWriteKBs: 500)
        check(noisy.holds(for: testProc(pid: 1, writeKBs: 800)),
              "a write rule holds above its rate", "")
        check(!noisy.holds(for: testProc(pid: 1, writeKBs: 100)),
              "a write rule fails below its rate", "")
        check(!noisy.holds(for: testProc(pid: 1, cpu: 900, memMB: 9000)),
              "a write rule ignores a process that is merely busy", "")

        let awake = WatchRule(name: "Never idle", minWakeups: 150)
        check(awake.holds(for: testProc(pid: 1, wakeups: 200)),
              "a wake-up rule holds above its rate", "")
        check(!awake.holds(for: testProc(pid: 1, wakeups: 100)),
              "a wake-up rule fails below its rate", "")

        // These are conditions like any other, so a rule made only of one is
        // not empty and the conjunction still applies.
        check(!noisy.isEmpty && !awake.isEmpty,
              "a rule made only of a rate is not empty", "")
        let both = WatchRule(name: "b", minCPU: 100, minWriteKBs: 500)
        check(both.holds(for: testProc(pid: 1, cpu: 200, writeKBs: 800)),
              "a rate and a threshold both holding matches", "")
        check(!both.holds(for: testProc(pid: 1, cpu: 50, writeKBs: 800)),
              "a rate holding does not excuse a threshold that does not", "")

        check(noisy.summary == "write \u{2265} 500 KB/s", "a write rule reads as a phrase",
              noisy.summary)
        check(awake.summary == "wakeups \u{2265} 150/s", "a wake-up rule reads as a phrase",
              awake.summary)
        check(fmtRate(800) == "800 B/s" && fmtRate(600 * 1024) == "600 KB/s"
                && fmtRate(3 * 1024 * 1024) == "3.0 MB/s",
              "fmtRate picks its scale", fmtRate(800) + " " + fmtRate(3 * 1024 * 1024))

        // Neither needs a permission, so they are usable in every profile.
        check(!noisy.needsInspection && !awake.needsInspection,
              "the two rates need nothing granted", "")
    }

    // MARK: - the accessibility window count

    /// The one parse in the app that has never run on a machine which granted
    /// the permission, so its fallbacks are checked here instead.
    private static func windowCounts(_ check: (Bool, String, String) -> Void) {
        check(windowCount(from: nil) == nil,
              "no value from the accessibility API is unknown, not zero", "")
        check(windowCount(from: "not a window list" as CFTypeRef) == nil,
              "something that is not a list is unknown, not zero", "")
        check(windowCount(from: 7 as CFTypeRef) == nil,
              "a number is unknown, not zero", "")
        // An app that answers with an empty list has told you something: none.
        check(windowCount(from: [] as CFArray) == 0,
              "an empty list is zero windows, which a rule may match on", "")
        check(windowCount(from: ["a", "b", "c"] as CFArray) == 3,
              "a list of three is three, whatever the bridge makes of the elements",
              "\(windowCount(from: ["a", "b", "c"] as CFArray) ?? -1)")

        // And the difference those two answers make to a rule.
        let rule = WatchRule(name: "w", states: [.windowless])
        check(rule.holds(for: testProc(pid: 1, gui: true, windows: 0)),
              "zero windows matches a no-window rule", "")
        check(!rule.holds(for: testProc(pid: 1, gui: true, windows: nil)),
              "unknown does not, which is why the fallback is nil", "")
    }

    // MARK: - exclusions

    private static func exclusions(_ check: (Bool, String, String) -> Void) {
        let helper = testProc(pid: 5,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        let app = testProc(pid: 6, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let tool = testProc(pid: 7, path: "/usr/local/bin/node")
        let zomb = testProc(pid: 8, path: "", zombie: true)

        // The outermost bundle, so excluding the browser excludes the six
        // helpers it will start next.
        check(helper.appPath == "/Applications/Google Chrome.app",
              "a helper's app path is the bundle it lives in", helper.appPath)
        check(app.appPath == "/Applications/Google Chrome.app",
              "so is the app's own", app.appPath)
        check(tool.appPath == "/usr/local/bin/node",
              "something with no bundle is its own executable", tool.appPath)
        check(zomb.appPath.isEmpty, "a zombie has no app path to exclude", zomb.appPath)
        check(app.appName == "Google Chrome" && tool.appName == "node",
              "the name is what a person would call it", app.appName + " / " + tool.appName)

        check(Exclusion(app)?.appPath == "/Applications/Google Chrome.app",
              "an exclusion can be made from a process", "")
        check(Exclusion(zomb) == nil, "but not from a zombie, which has nothing to match on", "")

        let rule = WatchRule(name: "r", minCPU: 100)
        let busy = [testProc(pid: 5, cpu: 900, path: helper.path),
                    testProc(pid: 7, cpu: 900, path: tool.path)]
        let tr = ProcTracker()
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        var v = tr.evaluate(busy, rules: [rule], now: t0)
        check(v.flagged.count == 2, "both are flagged with nothing excluded", "\(v.flagged.count)")

        let ex = excludedPaths([Exclusion(app)!])
        v = tr.evaluate(busy, rules: [rule], excluded: ex, now: t0)
        check(v.flagged.count == 1 && v.flagged.first?.proc.pid == 7,
              "excluding the bundle excludes its helper too", "\(v.flagged.map { $0.proc.pid })")

        // An excluded process must accumulate nothing, so un-excluding it makes
        // the rule earn its flag from zero rather than from a clock it kept
        // running the whole time. Only the excluded process here: the other one
        // in `busy` is not excluded and would rightly be flagged.
        let only = [testProc(pid: 5, cpu: 900, path: helper.path)]
        let slow = WatchRule(name: "s", minCPU: 100, sustain: 300)
        let tr2 = ProcTracker()
        _ = tr2.evaluate(only, rules: [slow], excluded: ex, now: t0)
        v = tr2.evaluate(only, rules: [slow], excluded: ex, now: t0 + 600)
        check(v.flagged.isEmpty && v.holding.isEmpty,
              "an excluded process is neither flagged nor counting", "\(v.flagged.count)")
        v = tr2.evaluate(only, rules: [slow], now: t0 + 601)
        check(v.flagged.isEmpty && v.holding.count == 1,
              "un-excluding it starts its clock from then, not from before",
              "\(v.flagged.count)/\(v.holding.count)")
        v = tr2.evaluate(only, rules: [slow], now: t0 + 901)
        check(v.flagged.count == 1,
              "and it is flagged a full sustain after that", "\(v.flagged.count)")

        check(excludedPaths([Exclusion(appPath: "", name: "junk")]).isEmpty,
              "an exclusion with no path matches nothing", "")
    }

    // MARK: - the log

    private static func log(_ check: (Bool, String, String) -> Void) {
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        let rule = WatchRule(name: "Runaway", minCPU: 300, sustain: 300)
        var l = FlagLog()

        let fresh = l.record([flag(testProc(pid: 9, cpu: 400), rule, held: 300)], now: t0)
        check(l.events.count == 1 && fresh.count == 1,
              "a new flag is recorded once and reported as new", "\(l.events.count)")
        check(l.events[0].began == t0 - 300,
              "the entry begins when the rule began holding, not when it fired", "")
        check(l.open.count == 1, "and it is open", "")

        // A second tick of the same thing updates it rather than adding.
        let again = l.record([flag(testProc(pid: 9, cpu: 900), rule, held: 360)], now: t0 + 60)
        check(l.events.count == 1 && again.isEmpty,
              "the same flag on the next tick is not a new event", "\(l.events.count)")
        check(l.events[0].peakCPU == 900, "the peak follows the worst reading",
              "\(l.events[0].peakCPU)")
        let dipped = l.record([flag(testProc(pid: 9, cpu: 400), rule, held: 420)], now: t0 + 120)
        check(l.events[0].peakCPU == 900, "and does not fall back", "\(l.events[0].peakCPU)")
        check(dipped.isEmpty, "a dip is not a new event", "")

        // Gone.
        _ = l.record([], now: t0 + 180)
        check(l.open.isEmpty && l.events[0].ended == l.events[0].lastSeen,
              "a flag that stops is closed at the last tick that saw it", "")
        check(abs(l.events[0].duration() - 420) < 1,
              "its duration spans from holding to gone", "\(l.events[0].duration())")

        // The same process flagged again is a second thing to have happened.
        let back = l.record([flag(testProc(pid: 9, cpu: 400), rule, held: 300)], now: t0 + 600)
        check(l.events.count == 2 && back.count == 1,
              "the same process flagged again is a new event", "\(l.events.count)")
        check(l.events[0].began > l.events[1].began, "newest first", "")

        // A reused pid must not extend someone else's entry.
        var l2 = FlagLog()
        _ = l2.record([flag(testProc(pid: 10, cpu: 400, started: 1), rule)], now: t0)
        _ = l2.record([flag(testProc(pid: 10, cpu: 400, started: 2), rule)], now: t0 + 60)
        check(l2.events.count == 2, "a reused pid gets its own entry", "\(l2.events.count)")

        // Two rules on one process are two things to know.
        var l3 = FlagLog()
        let other = WatchRule(name: "Memory hog", minMemoryMB: 4096)
        _ = l3.record([flag(testProc(pid: 11, cpu: 400), rule)], now: t0)
        _ = l3.record([flag(testProc(pid: 11, cpu: 400), other)], now: t0 + 60)
        check(l3.events.count == 2, "a different rule is a different event", "\(l3.events.count)")

        // "It went away" and "I ended it" are different answers.
        var l4 = FlagLog()
        _ = l4.record([flag(testProc(pid: 12, cpu: 400, started: 7), rule)], now: t0)
        check(l4.events[0].signalled == false, "an entry starts unsignalled", "")
        l4.markSignalled(pid: 12, startedMicros: 7)
        check(l4.events[0].signalled, "and records that a signal went out", "")
        l4.markSignalled(pid: 99, startedMicros: 7)
        check(l4.events.allSatisfy { $0.pid == 12 || !$0.signalled },
              "signalling another pid leaves this one alone", "")

        // Bounded.
        var l5 = FlagLog(limit: 3)
        for i in 0..<6 {
            _ = l5.record([flag(testProc(pid: pid_t(20 + i), cpu: 400, started: UInt64(i)), rule)],
                          now: t0 + Double(i) * 60)
        }
        check(l5.events.count == 3, "the log is bounded", "\(l5.events.count)")
        check(l5.events.first?.pid == 25, "and keeps the newest", "\(l5.events.first?.pid ?? -1)")

        // Read back from a previous run, nothing can still be open.
        var l6 = FlagLog()
        _ = l6.record([flag(testProc(pid: 30, cpu: 400), rule)], now: t0)
        check(l6.open.count == 1, "open before closing", "")
        l6.closeOpen()
        check(l6.open.isEmpty, "closeOpen closes what a previous run left open", "")

        var l7 = FlagLog()
        _ = l7.record([flag(testProc(pid: 31, cpu: 400), rule)], now: t0)
        l7.clear()
        check(l7.events.isEmpty, "the log can be emptied", "")
    }

    // MARK: - storage

    private static func storage(_ check: (Bool, String, String) -> Void) {
        let d = testDefaults()
        check(Store.loadExclusions(d).isEmpty, "an empty domain has no exclusions", "")
        check(Store.loadHistory(d).events.isEmpty, "an empty domain has no history", "")

        let x = [Exclusion(appPath: "/Applications/Xcode.app", name: "Xcode")]
        Store.saveExclusions(x, d)
        check(Store.loadExclusions(d) == x, "exclusions round trip", "")
        d.set(Data("not json".utf8), forKey: Store.exclusionsKey)
        check(Store.loadExclusions(d).isEmpty, "an unreadable list is simply empty", "")

        var l = FlagLog()
        let rule = WatchRule(name: "Runaway", minCPU: 300)
        _ = l.record([flag(testProc(pid: 40, cpu: 500), rule)],
                     now: Date(timeIntervalSince1970: 7_000_000))
        Store.saveHistory(l, d)
        let back = Store.loadHistory(d)
        check(back.events.count == 1, "history round trips", "\(back.events.count)")
        check(back.open.isEmpty,
              "and comes back closed: it was open when the app stopped, not now", "")
        check(back.events[0].peakCPU == 500 && back.events[0].rule == "Runaway",
              "with its readings intact", "")

        // An event written by a version with fewer fields still loads.
        let old = Data("[{\"name\":\"old\",\"rule\":\"R\",\"pid\":1}]".utf8)
        if let e = try? JSONDecoder().decode([FlagEvent].self, from: old), let f = e.first {
            check(f.name == "old" && f.peakWriteRate == 0 && !f.signalled,
                  "an event written with fewer fields loads with defaults", "")
        } else {
            check(false, "an event written with fewer fields loads at all", "")
        }

        // Pause.
        var st = WatchSettings()
        check(!st.paused(), "a fresh install is not paused", "")
        let now = Date(timeIntervalSince1970: 8_000_000)
        st.pausedUntil = now + 600
        check(st.paused(now), "a pause in the future is a pause", "")
        check(!st.paused(now + 900), "a pause that has run out is over", "")
        Store.saveSettings(st, d)
        check(Store.loadSettings(d).pausedUntil != nil, "a pause survives a relaunch", "")

        // A hand-edited pause that would outlast anything the app offers is
        // dropped rather than switching the watch off for ever.
        let silly = Data("{\"poll\":5,\"pausedUntil\":4102444800}".utf8)
        if let s = try? JSONDecoder().decode(WatchSettings.self, from: silly) {
            // Not force-unwrapped: the detail is evaluated whether the check
            // passes or not, and it is nil exactly when it passes.
            check(s.pausedUntil == nil, "an absurd stored pause is discarded",
                  s.pausedUntil.map { "\($0)" } ?? "nil")
        } else {
            check(false, "settings with an absurd pause load at all", "")
        }
        check(WatchSettings().notify == false, "notifications are off by default", "")
        d.removePersistentDomain(forName: "com.local.reaper.tests")
    }
}
