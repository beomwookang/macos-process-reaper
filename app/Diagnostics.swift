//
// What the app currently sees, as text.
//
// The mark has three states and carries no text in two of them, which makes
// "why is it amber" a question a screenshot cannot answer. This is the answer:
// which profile is loaded, what the sampler found, what each rule made of it,
// and which colour the mark would therefore be.
//
// One function, two callers: `Reaper --diagnose` prints it, and the About
// window copies it to the clipboard so it can be pasted into a bug report. A
// report that comes with this in it needs no follow-up questions.
//
// Model only, and linked into the test binary: it takes its own tracker and its
// own defaults so it cannot disturb the running app's sampling state.
//

import AppKit
import Foundation

/// `settle` is how long to wait between the two samples. The first has no
/// interval to divide by, so every CPU figure in it is zero; two seconds is
/// long enough for the second to mean something and short enough that a menu
/// item using this does not feel stuck.
func diagnosticsText(_ d: UserDefaults = .standard, settle: TimeInterval = 2) -> String {
    var out: [String] = []
    func line(_ s: String = "") { out.append(s) }
    func field(_ k: String, _ v: String) {
        line("\(k.padding(toLength: 17, withPad: " ", startingAt: 0))\(v)")
    }

    let profiles = Store.loadProfiles(d)
    let activeID = Store.loadActive(profiles, d)
    let settings = Store.loadSettings(d)
    let active = profiles.first { $0.id == activeID }

    line("\(APP_NAME) \(appVersion)")
    field("defaults domain:", Bundle.main.bundleIdentifier ?? "none -- not running from the bundle")
    field("macOS:", ProcessInfo.processInfo.operatingSystemVersionString)
    field("profiles:", profiles.map { $0.name }.joined(separator: ", "))
    field("active:", "\(active?.name ?? "?")  -- \(active?.detail ?? "")")
    field("poll:", "\(Int(settings.poll)) s")
    field("inspect apps:", "\(settings.inspectApps)")
    field("login item:", "\(LoginItem.enabled)")
    line()

    let tracker = ProcTracker()
    let gui = guiAppPIDs()
    let (ctx, cap) = liveContext(guiApps: gui, inspectApps: settings.inspectApps)
    _ = tracker.sample(ctx)
    Thread.sleep(forTimeInterval: settle)
    let procs = tracker.sample(ctx)
    let verdict = tracker.evaluate(procs, rules: active?.rules ?? [])

    field("capability:", "appsInspected=\(cap.appsInspected)"
          + (cap.reason.isEmpty ? "" : "  (\(cap.reason))"))
    field("sampled:", "\(procs.count) processes, \(gui.count) of them apps")
    field("zombies:", "\(procs.filter { $0.isZombie }.count)")
    field("orphans:", "\(procs.filter { $0.isOrphan }.count)")
    line()

    line("rules of \(active?.name ?? "?"):")
    for r in active?.rules ?? [] {
        let why = r.inactiveReason(cap)
        line("  \(r.enabled ? "on " : "off") "
             + "\(r.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(r.summary)"
             + (why == nil ? "" : "   [inactive: \(why!)]"))
    }
    line()

    line("flagged: \(verdict.flagged.count)")
    for f in verdict.flagged {
        line("  \(f.proc.name) (\(f.proc.pid))  \(fmtCPU(f.proc.cpu))"
             + "  by \(f.rule.name)  held \(fmtAge(f.heldFor))")
    }
    line("counting: \(verdict.holding.count)")
    for h in verdict.holding {
        line("  \(h.proc.name) (\(h.proc.pid))  \(fmtCPU(h.proc.cpu))"
             + "  towards \(h.rule.name)  \(Int(h.progress * 100))% of \(fmtAge(h.rule.sustain))")
    }
    line()
    line("the mark would be: \(markDescription(verdict))")
    return out.joined(separator: "\n")
}

/// What the mark is saying, in words. Shared so the diagnostics and the status
/// item's tooltip cannot describe the same verdict differently.
func markDescription(_ v: ProcTracker.Verdict) -> String {
    if !v.flagged.isEmpty { return "flagged \(v.flagged.count)" }
    if !v.holding.isEmpty { return "holding \(v.holding.count)" }
    return "calm"
}
