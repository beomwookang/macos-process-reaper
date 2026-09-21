//
// Checks for the rules: the thresholds, the states, the phrasing, the profiles,
// and what survives being written to defaults and read back.
//
// The states are where the care is needed. Three of the four can be unknown --
// the window server may not answer, the hang probe may be off -- and a watchdog
// that flags everything it cannot see is worse than one that flags nothing, so
// every unknown is checked to make sure it does not match.
//

import Foundation

enum RuleTests {
    static func run(_ check: (Bool, String, String) -> Void) {
        thresholds(check)
        states(check)
        phrasing(check)
        capability(check)
        coding(check)
        profiles(check)
        storage(check)
        settings(check)
    }

    // MARK: - thresholds

    private static func thresholds(_ check: (Bool, String, String) -> Void) {
        let runaway = WatchRule(name: "Runaway", minCPU: 300, sustain: 300)
        check(runaway.holds(for: testProc(pid: 1, cpu: 350)), "CPU threshold holds above it", "")
        check(!runaway.holds(for: testProc(pid: 1, cpu: 250)), "CPU threshold fails below it", "")

        check(!WatchRule(name: "empty").holds(for: testProc(pid: 1, cpu: 900, memMB: 9000, ageH: 99)),
              "a rule with nothing set matches nothing, not everything", "")

        let busy = WatchRule(name: "busy", minCPU: 50, minAgeHours: 12)
        check(!busy.holds(for: testProc(pid: 1, cpu: 80, ageH: 1)),
              "every set threshold must hold", "age 1 h")
        check(busy.holds(for: testProc(pid: 1, cpu: 80, ageH: 13)),
              "all thresholds holding matches", "")

        let mem = WatchRule(name: "mem", minMemoryMB: 4096)
        check(mem.holds(for: testProc(pid: 1, memMB: 5000)), "memory threshold holds above it", "")
        check(!mem.holds(for: testProc(pid: 1, cpu: 900, memMB: 4000)),
              "memory threshold fails below it", "")
    }

    // MARK: - states

    private static func states(_ check: (Bool, String, String) -> Void) {
        let zombie = WatchRule(name: "Zombie", states: [.zombie])
        check(zombie.holds(for: testProc(pid: 1, path: "", zombie: true)), "a zombie rule matches a zombie", "")
        check(!zombie.holds(for: testProc(pid: 1, cpu: 900)), "a zombie rule does not match a live process", "")

        let orphan = WatchRule(name: "Orphan", states: [.orphan])
        check(orphan.holds(for: testProc(pid: 5, ppid: 1)), "an orphan rule matches a process launchd adopted", "")
        check(!orphan.holds(for: testProc(pid: 5, ppid: 400)), "an orphan rule does not match a parented process", "")
        check(!orphan.holds(for: testProc(pid: 1, ppid: 1)), "launchd itself is not an orphan", "")
        // launchd is the direct parent of every agent macOS ships, so without
        // this the state reads as true for most of the process table.
        check(!orphan.holds(for: testProc(pid: 5, ppid: 1, path: "/usr/libexec/trustd")),
              "something macOS ships is not an orphan for having launchd as its parent", "")
        check(!orphan.holds(for: testProc(pid: 5, ppid: 1, path: "/System/Library/X")),
              "nothing under /System is an orphan", "")
        check(orphan.holds(for: testProc(pid: 5, ppid: 1, path: "/usr/local/bin/node")),
              "something the user installed is", "")

        // Windows. Unknown has to be distinguishable from none: nil means the
        // window server was not asked, an empty count means it answered.
        let windowless = WatchRule(name: "Forgotten", states: [.windowless])
        check(windowless.holds(for: testProc(pid: 7, gui: true, windows: 0)),
              "a no-window rule matches a GUI app with nothing on screen", "")
        check(!windowless.holds(for: testProc(pid: 7, gui: true, windows: 2)),
              "a no-window rule does not match an app with a window", "")
        check(!windowless.holds(for: testProc(pid: 7, gui: false, windows: 0)),
              "a no-window rule does not match a process that was never going to have one", "")
        check(!windowless.holds(for: testProc(pid: 7, gui: true, windows: nil)),
              "a rule needing window information flags nothing while apps are not being asked", "")
        check(testProc(pid: 7, gui: true, windows: nil).isWindowless == nil,
              "an unasked window count reads as unknown, not as zero", "")

        // The hang probe. Off means unknown, and unknown is not a match.
        let hung = WatchRule(name: "Not responding", states: [.unresponsive])
        check(hung.holds(for: testProc(pid: 9, gui: true, responsive: false)),
              "a not-responding rule matches an app that did not answer", "")
        check(!hung.holds(for: testProc(pid: 9, gui: true, responsive: true)),
              "a not-responding rule does not match an app that answered", "")
        check(!hung.holds(for: testProc(pid: 9, gui: true, responsive: nil)),
              "a rule needing responsiveness flags nothing while apps are not being asked", "")

        // States and thresholds are one conjunction, not two alternatives.
        let both = WatchRule(name: "both", minCPU: 100, states: [.orphan])
        check(both.holds(for: testProc(pid: 3, ppid: 1, cpu: 200)),
              "a state and a threshold both holding matches", "")
        check(!both.holds(for: testProc(pid: 3, ppid: 1, cpu: 50)),
              "a state holding does not excuse a threshold that does not", "")
        check(!both.holds(for: testProc(pid: 3, ppid: 900, cpu: 200)),
              "a threshold holding does not excuse a state that does not", "")

        let two = WatchRule(name: "two", states: [.orphan, .windowless])
        check(two.holds(for: testProc(pid: 4, ppid: 1, gui: true, windows: 0)),
              "every state a rule lists has to hold", "")
        check(!two.holds(for: testProc(pid: 4, ppid: 1, gui: true, windows: 3)),
              "one state of two failing is enough to fail the rule", "")

        // A rule with a state and no numbers is not empty: this is how the
        // zombie and not-responding rules are expressed at all.
        check(!WatchRule(name: "s", states: [.zombie]).isEmpty,
              "a rule with a state and no thresholds is not empty", "")
    }

    // MARK: - phrasing

    private static func phrasing(_ check: (Bool, String, String) -> Void) {
        let runaway = WatchRule(name: "Runaway", minCPU: 300, sustain: 300)
        check(runaway.summary == "CPU \u{2265} 300% \u{00B7} for 5 min",
              "a threshold rule reads as a phrase", runaway.summary)

        let z = WatchRule(name: "Zombie", states: [.zombie])
        check(z.summary == "zombie", "a state rule reads as the state", z.summary)

        let mixed = WatchRule(name: "m", minCPU: 25, minAgeHours: 1,
                              states: [.windowless], sustain: 600)
        check(mixed.summary == "no window \u{00B7} CPU \u{2265} 25% \u{00B7} age \u{2265} 1 h \u{00B7} for 10 min",
              "states come before thresholds in a summary", mixed.summary)

        check(WatchRule(name: "e").summary == "nothing set", "an empty rule says so", "")

        // The order is the declaration order of the enum, not the set's, so the
        // same rule reads the same way every time it is drawn.
        let all = WatchRule(name: "a", states: Set(WatchState.allCases))
        check(all.summary == "zombie \u{00B7} orphan \u{00B7} no window \u{00B7} not responding",
              "state order in a summary is stable", all.summary)
    }

    // MARK: - capability

    private static func capability(_ check: (Bool, String, String) -> Void) {
        var cap = WatchCapability()
        let hung = WatchRule(name: "h", states: [.unresponsive])
        let win = WatchRule(name: "w", states: [.windowless])
        let plain = WatchRule(name: "p", minCPU: 100)

        check(hung.inactiveReason(cap) == cap.reason && !cap.reason.isEmpty,
              "a not-responding rule says why it cannot see", hung.inactiveReason(cap) ?? "nil")
        check(win.inactiveReason(cap) == cap.reason,
              "a no-window rule gives the same reason: it is the same call", win.inactiveReason(cap) ?? "nil")
        check(plain.inactiveReason(cap) == nil,
              "a threshold rule needs no capability", plain.inactiveReason(cap) ?? "nil")
        check(hung.needsInspection && win.needsInspection && !plain.needsInspection,
              "only the two accessibility states need apps to be asked", "")

        cap.appsInspected = true
        cap.reason = ""
        check(hung.inactiveReason(cap) == nil && win.inactiveReason(cap) == nil,
              "a rule whose capability is available is active", "")

        var off = plain
        off.enabled = false
        check(off.inactiveReason(cap) == nil,
              "a disabled rule reports no reason: it was switched off on purpose", "")
        check(WatchRule(name: "n").inactiveReason(cap) == "nothing set",
              "an empty rule reports that as its reason", "")
    }

    // MARK: - coding

    private static func coding(_ check: (Bool, String, String) -> Void) {
        let rules = builtInProfiles.flatMap { $0.rules }
        if let data = try? JSONEncoder().encode(rules),
           let back = try? JSONDecoder().decode([WatchRule].self, from: data) {
            check(back == rules, "every shipped rule survives an encode/decode round trip", "")
        } else {
            check(false, "shipped rules encode and decode", "")
        }

        // Forward tolerance: a file written before states existed.
        let old = Data("[{\"name\":\"Old\",\"minCPU\":100}]".utf8)
        if let r = try? JSONDecoder().decode([WatchRule].self, from: old), let f = r.first {
            check(f.enabled && f.sustain == 0 && f.minCPU == 100 && f.minMemoryMB == nil
                    && f.states.isEmpty,
                  "a rule written with fewer fields loads with defaults", "\(f)")
        } else {
            check(false, "a rule written with fewer fields loads at all", "")
        }

        // Backward tolerance: a state this version does not know about is
        // dropped, and the rest of the rule still loads.
        let future = Data("[{\"name\":\"New\",\"minCPU\":10,\"states\":[\"orphan\",\"quantum\"]}]".utf8)
        if let r = try? JSONDecoder().decode([WatchRule].self, from: future), let f = r.first {
            check(f.states == [.orphan] && f.minCPU == 10,
                  "an unknown state is dropped rather than failing the rule", "\(f.states)")
        } else {
            check(false, "a rule with an unknown state loads at all", "")
        }

        // States are written sorted, so an unchanged rule produces unchanged
        // bytes and a diff of the defaults stays readable.
        let two = WatchRule(name: "t", states: [.windowless, .orphan])
        if let data = try? JSONEncoder().encode(two),
           let text = String(data: data, encoding: .utf8) {
            check(text.contains("[\"orphan\",\"windowless\"]"),
                  "states are encoded in a stable order", text)
        } else {
            check(false, "a rule with states encodes", "")
        }
    }

    // MARK: - profiles

    private static func profiles(_ check: (Bool, String, String) -> Void) {
        check(builtInProfiles.count == 3, "three profiles ship", "\(builtInProfiles.count)")
        check(Set(builtInProfiles.map { $0.id }).count == 3,
              "shipped profiles have distinct identifiers", "")
        let ruleIDs = builtInProfiles.flatMap { $0.rules.map { $0.id } }
        check(Set(ruleIDs).count == ruleIDs.count,
              "every shipped rule has an identifier of its own", "\(ruleIDs.count)")
        check(builtInProfiles.allSatisfy { !$0.rules.isEmpty && $0.builtIn && !$0.detail.isEmpty },
              "every shipped profile has rules, a detail phrase, and is marked built in", "")
        check(builtInProfiles.allSatisfy { $0.rules.allSatisfy { $0.enabled && !$0.isEmpty } },
              "every shipped rule is enabled and sets something", "")

        // An orphan rule with no threshold would flag every XPC service and
        // crashpad handler launchd parents, which is most of what is running.
        let looseOrphan = builtInProfiles.flatMap { $0.rules }.filter {
            $0.states.contains(.orphan) && $0.minCPU == nil && $0.minMemoryMB == nil
        }
        check(looseOrphan.isEmpty,
              "no shipped orphan rule flags on the state alone", "\(looseOrphan.map { $0.name })")
        check(builtInProfiles.contains { $0.id == defaultProfileID },
              "the default profile is one that ships", "")

        // Only Aggressive asks for a capability that may not be there, so the
        // other two work on a machine that has granted nothing. This is the
        // check that keeps a state needing Accessibility from drifting into a
        // profile that promises not to need it.
        let needy = builtInProfiles.filter { $0.rules.contains { $0.needsInspection } }
        check(needy.count == 1 && needy.first?.name == "Aggressive",
              "only the Aggressive profile needs Accessibility", "\(needy.map { $0.name })")

        // Restoring: an edited shipped profile goes back, a deleted one comes
        // back, a user's own is left alone.
        var edited = builtInProfiles[0]
        edited.rules[0].minCPU = 999
        edited.name = "Renamed"
        let mine = Profile(name: "Mine", detail: "just mine",
                           rules: [WatchRule(name: "r", minCPU: 10)])
        let restored = restoringProfiles([edited, mine])
        check(restored.count == builtInProfiles.count + 1,
              "restore re-adds deleted profiles and keeps the user's own",
              "\(restored.map { $0.name })")
        check(restored.first { $0.id == builtInProfiles[0].id } == builtInProfiles[0],
              "restore puts an edited profile back as shipped, name included", "")
        check(restored.contains { $0.name == "Mine" && $0.rules.first?.minCPU == 10 },
              "restore leaves a profile of the user's own alone", "")
        check(restoringProfiles(builtInProfiles) == builtInProfiles,
              "restoring an untouched list changes nothing", "")
        check(restoringProfiles([mine]).map { $0.name }.last == "Mine",
              "restore does not reorder the user's profile ahead of the shipped ones",
              "\(restoringProfiles([mine]).map { $0.name })")
    }

    // MARK: - storage

    private static func storage(_ check: (Bool, String, String) -> Void) {
        let d = testDefaults()

        check(Store.loadProfiles(d) == builtInProfiles,
              "an empty domain loads the shipped profiles", "")
        check(Store.loadActive(Store.loadProfiles(d), d) == defaultProfileID,
              "an empty domain starts on the default profile", "")

        var ps = builtInProfiles
        ps.append(Profile(name: "Mine", detail: "mine", rules: [WatchRule(name: "r", minCPU: 5)]))
        Store.saveProfiles(ps, d)
        check(Store.loadProfiles(d) == ps, "profiles round trip through defaults", "")

        let mineID = ps.last!.id
        Store.saveActive(mineID, d)
        check(Store.loadActive(ps, d) == mineID, "the active profile round trips", "")

        // The profile that was active has since been deleted. Falling through to
        // nothing would leave the app with no rules at all.
        check(Store.loadActive(builtInProfiles, d) == defaultProfileID,
              "an active profile that no longer exists falls back to the default", "")
        let onlyMine = [ps.last!]
        check(Store.loadActive(onlyMine, d) == mineID,
              "with the default gone, the first profile is used", "")

        // A corrupt or empty stored list is not allowed to leave no rules.
        d.set(Data("[]".utf8), forKey: Store.profilesKey)
        check(Store.loadProfiles(d) == builtInProfiles,
              "an empty stored list falls back to the shipped profiles", "")
        d.set(Data("not json".utf8), forKey: Store.profilesKey)
        check(Store.loadProfiles(d) == builtInProfiles,
              "an unreadable stored list falls back to the shipped profiles", "")

        var s = WatchSettings()
        s.poll = 30
        s.inspectApps = true
        s.showAll = true
        Store.saveSettings(s, d)
        check(Store.loadSettings(d) == s, "settings round trip through defaults", "")
        d.removePersistentDomain(forName: "com.local.reaper.tests")
    }

    private static func settings(_ check: (Bool, String, String) -> Void) {
        check(WatchSettings().poll == 5 && WatchSettings().inspectApps == false,
              "asking apps about themselves is off by default, and the poll is five seconds", "")

        // The switch used to be called probeHangs, when it only drove the hang
        // probe. A settings file from then has to keep the choice it recorded.
        let legacy = Data("{\"poll\":10,\"probeHangs\":true}".utf8)
        if let s = try? JSONDecoder().decode(WatchSettings.self, from: legacy) {
            check(s.inspectApps && s.poll == 10,
                  "the old name of the inspect switch is still read", "\(s)")
        } else {
            check(false, "settings under the old key name load at all", "")
        }

        // A zero poll from a hand-edited plist would be a timer that never stops
        // firing, so it is clamped on the way in rather than trusted.
        let zero = Data("{\"poll\":0,\"inspectApps\":false,\"showAll\":false}".utf8)
        if let s = try? JSONDecoder().decode(WatchSettings.self, from: zero) {
            check(s.poll >= 1, "a nonsensical stored poll is clamped, not obeyed", "\(s.poll)")
        } else {
            check(false, "settings with a nonsensical poll load at all", "")
        }
        let missing = Data("{}".utf8)
        if let s = try? JSONDecoder().decode(WatchSettings.self, from: missing) {
            check(s.poll == 5, "settings written with fewer fields load with defaults", "\(s.poll)")
        } else {
            check(false, "settings written with fewer fields load at all", "")
        }
    }
}

// MARK: - diagnostics

/// The text the About window copies and `--diagnose` prints. Checked for the
/// lines a bug report is useless without, rather than against a fixed string:
/// what it says about this machine depends on the machine.
enum DiagnosticsTests {
    static func run(_ check: (Bool, String, String) -> Void) {
        let d = testDefaults()
        // settle: 0 so the suite does not spend two seconds waiting for a
        // second sample it is not going to read the CPU figures from.
        let text = diagnosticsText(d, settle: 0)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for want in ["defaults domain:", "bundle:", "macOS:", "profiles:", "active:", "poll:",
                     "inspect apps:", "notify:", "paused:", "never flagged:", "capability:",
                     "sampled:", "zombies:", "orphans:", "flagged:", "counting:", "history:",
                     "the mark would be:"] {
            check(lines.contains { $0.contains(want) },
                  "diagnostics report \"\(want)\"", "")
        }
        check(text.hasPrefix("Reaper "), "diagnostics open with the app and its version",
              String(text.prefix(20)))
        // Which copy is running decides whether the accessibility states can
        // work at all, so a report has to carry it.
        check(lines.contains { $0.contains("bundle:") && $0.contains("/") },
              "diagnostics name the bundle they were taken from", "")
        check(lines.contains { $0.contains("rules of Balanced") },
              "diagnostics name the active profile's rules", "")
        // Every shipped rule has to appear, or a report would not say which
        // ones were switched off.
        for r in builtInProfiles[1].rules {
            check(lines.contains { $0.contains(r.name) && $0.contains(r.summary) },
                  "diagnostics list the \"\(r.name)\" rule with its summary", "")
        }
        check(lines.last?.contains("calm") == true || lines.last?.contains("flagged") == true
                || lines.last?.contains("holding") == true,
              "diagnostics end with which colour the mark would be", lines.last ?? "")

        // The description the tooltip and the diagnostics share.
        var v = ProcTracker.Verdict()
        check(markDescription(v) == "calm", "an empty verdict is calm", markDescription(v))
        let f = ProcTracker.Flag(proc: testProc(pid: 1, cpu: 900),
                                 rule: WatchRule(name: "r", minCPU: 100),
                                 heldFor: 10, sustained: true)
        v.flagged = [f]
        check(markDescription(v) == "flagged 1", "a flagged verdict counts them", markDescription(v))
        v.flagged = []
        v.holding = [f]
        check(markDescription(v) == "holding 1", "a holding verdict counts them", markDescription(v))
    }
}
