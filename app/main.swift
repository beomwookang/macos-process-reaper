//
// Reaper: a menu bar watch for processes nobody remembers starting.
//
// The mark in the bar is calm until a rule holds, and red when one does. That
// correspondence is the whole product: if the mark is calm, the rules you chose
// have nothing to report, and if it is red, something is named one click away.
//
// Nothing is ever killed automatically. A rule flags; a person decides. An app
// that ended processes on its own would be a worse version of the problem it
// exists to find.
//

import AppKit
import ApplicationServices
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?

    // MARK: model

    private var profiles = Store.loadProfiles()
    private var activeID: UUID
    private var settings = Store.loadSettings()

    private var activeRules: [WatchRule] {
        profiles.first { $0.id == activeID }?.rules ?? []
    }

    /// Sampled on its own serial queue every tick, whether or not a window is
    /// open, because "sustained" needs the history: a runaway noticed only when
    /// someone looks is noticed late. The queue is also where the accessibility
    /// probe runs, which is the other reason it is not the main one.
    private let tracker = ProcTracker()
    private let sampleQueue = DispatchQueue(label: "com.local.reaper.sample", qos: .utility)

    private var load: SystemLoad?
    private var procs: [ProcSample] = []
    private var verdict = ProcTracker.Verdict()
    private var capability = WatchCapability()

    /// When SIGTERM went out, per pid. The one record, shared with every window.
    private var termSent: [pid_t: Date] = [:]
    private let grace: TimeInterval = 3

    // MARK: windows

    private var processes: ProcessWindow?
    /// One detail window per process, keyed by pid: opening the same row twice
    /// should raise the window that is already there.
    private var details: [pid_t: DetailWindow] = [:]

    // MARK: menu

    private let headline = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var procItems: [NSMenuItem] = []
    private let procEmpty = NSMenuItem(title: "Nothing flagged", action: nil, keyEquivalent: "")
    private let procEnd = NSMenuItem.separator()
    private let profileMenu = NSMenu()
    private let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
    private let inspectItem = NSMenuItem(title: "", action: #selector(toggleInspect), keyEquivalent: "")
    private let pollMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin),
                                       keyEquivalent: "")

    override init() {
        activeID = Store.loadActive(profiles)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly

        buildMenu()
        drawMark()
        refresh()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.poll, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - the menu

    private func buildMenu() {
        let m = NSMenu()
        m.delegate = self

        headline.isEnabled = false
        m.addItem(headline)
        m.addItem(.separator())

        // Flagged processes go here, one row each, above procEnd. Filled in by
        // rebuildRows on every tick; until the first one, the quiet line.
        procEmpty.isEnabled = false
        m.addItem(procEmpty)
        m.addItem(procEnd)

        profileMenu.delegate = self
        profileItem.submenu = profileMenu
        m.addItem(profileItem)

        let open = NSMenuItem(title: "Processes & Rules\u{2026}", action: #selector(openProcesses),
                              keyEquivalent: ",")
        open.target = self
        m.addItem(open)

        m.addItem(.separator())

        inspectItem.target = self
        inspectItem.title = "Inspect Apps for Windows & Hangs"
        m.addItem(inspectItem)

        for s in WatchSettings.pollChoices {
            let mi = NSMenuItem(title: s >= 60 ? "\(Int(s / 60)) min" : "\(Int(s)) s",
                                action: #selector(setPoll(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s
            pollMenu.addItem(mi)
        }
        let pollItem = NSMenuItem(title: "Sample Every", action: nil, keyEquivalent: "")
        pollItem.submenu = pollMenu
        m.addItem(pollItem)

        m.addItem(.separator())
        loginItem.target = self
        m.addItem(loginItem)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Reaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        item.menu = m
    }

    // Refresh while the menu is open too, so the numbers you are reading are
    // not the ones from before you clicked.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === item.menu { refresh() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === profileMenu else { return }
        menu.removeAllItems()
        for p in profiles {
            let mi = NSMenuItem(title: "\(p.name)  \u{2014}  \(p.detail)",
                                action: #selector(pickProfile(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = p.id == activeID ? .on : .off
            mi.representedObject = p.id.uuidString
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let restore = NSMenuItem(title: "Restore Profiles", action: #selector(restoreProfiles),
                                 keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
    }

    /// The rows are re-made only when the set of flagged pids changes; with the
    /// same set, the existing rows are handed the new numbers. Re-making them
    /// every tick would make an open menu jump under the pointer.
    private func rebuildRows() {
        guard let m = item.menu, m.index(of: procEnd) >= 0 else { return }
        let flags = verdict.flagged
        let want = flags.map { $0.proc.pid }
        let have = procItems.compactMap { ($0.view as? ProcessRowView)?.proc?.pid }
        if want != have {
            for mi in procItems { m.removeItem(mi) }
            procItems = []
            if flags.isEmpty {
                if m.index(of: procEmpty) < 0 { m.insertItem(procEmpty, at: m.index(of: procEnd)) }
            } else {
                if m.index(of: procEmpty) >= 0 { m.removeItem(procEmpty) }
                for _ in flags {
                    let row = ProcessRowView()
                    row.button.target = self
                    row.button.action = #selector(killRow(_:))
                    let mi = NSMenuItem()
                    mi.view = row
                    m.insertItem(mi, at: m.index(of: procEnd))
                    procItems.append(mi)
                }
            }
        }
        for (mi, f) in zip(procItems, flags) {
            let parent = parentOf(f.proc)
            let target = killTarget(f.proc, parent: parent)
            (mi.view as? ProcessRowView)?.show(f, parent: parent,
                                               termSentAt: termSent[target?.pid ?? f.proc.pid],
                                               grace: grace)
        }
        // The quiet line carries the one thing the mark cannot: that something
        // is counting, and nothing has been flagged yet.
        if flags.isEmpty {
            let n = verdict.holding.count
            procEmpty.title = n == 0
                ? "Nothing flagged"
                : "Nothing flagged \u{2014} \(n) still counting"
        }
    }

    // MARK: - the tick

    private func refresh() {
        // NSWorkspace is a main-thread API, so the app list is gathered here and
        // handed over. Everything else -- the proc tables, and the accessibility
        // probe that deliberately waits on apps that are not answering -- runs
        // on the sample queue, where a slow answer costs nothing.
        let gui = guiAppPIDs()
        let rules = activeRules
        let inspect = settings.inspectApps
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let (ctx, cap) = liveContext(guiApps: gui, inspectApps: inspect)
            let procs = self.tracker.sample(ctx)
            let verdict = self.tracker.evaluate(procs, rules: rules)
            let load = self.tracker.systemLoad()
            let traces = Dictionary(uniqueKeysWithValues:
                self.details.keys.map { ($0, self.tracker.traceFor($0)) })
            DispatchQueue.main.async {
                self.apply(load, procs, verdict, cap, traces)
            }
        }
    }

    private func apply(_ load: SystemLoad, _ procs: [ProcSample], _ verdict: ProcTracker.Verdict,
                       _ cap: WatchCapability, _ traces: [pid_t: [Double]]) {
        self.load = load
        self.procs = procs
        self.verdict = verdict
        self.capability = cap

        let alive = Set(procs.map { $0.pid })
        termSent = termSent.filter { alive.contains($0.key) }

        drawMark()
        headline.title = ProcessWindow.headlineText(load)
        rebuildRows()
        inspectItem.state = settings.inspectApps ? .on : .off
        inspectItem.toolTip = cap.appsInspected
            ? "Asking each app about its windows and whether it is answering."
            : "Needs Accessibility. " + (cap.reason.isEmpty ? "" : cap.reason + ".")
        loginItem.state = LoginItem.enabled ? .on : .off
        for mi in pollMenu.items {
            mi.state = (mi.representedObject as? TimeInterval) == settings.poll ? .on : .off
        }

        if processes?.window?.isVisible == true {
            processes?.update(load: load, procs: procs, verdict: verdict,
                              capability: cap, termSent: termSent)
        }
        for (pid, w) in details {
            guard w.window?.isVisible == true else { details.removeValue(forKey: pid); continue }
            let p = procs.first { $0.pid == pid }
            let flag = (verdict.flagged + verdict.holding).first { $0.proc.pid == pid }
            w.update(p, chain: p.map(parentChain) ?? [], flag: flag,
                     trace: traces[pid] ?? [], poll: settings.poll, termSent: termSent[pid])
        }
    }

    /// Calm, amber while something is counting, red once something is flagged.
    /// Drawn under the button's own appearance: a dynamic colour resolved
    /// outside it would be stale after a light/dark switch.
    private func drawMark() {
        let state: MarkState
        if !verdict.flagged.isEmpty {
            state = .flagged(verdict.flagged.count)
        } else if !verdict.holding.isEmpty {
            state = .holding(verdict.holding.count)
        } else {
            state = .calm
        }
        // Annotated: an optional-chained assignment makes the closure return
        // ()? , which is not what performAsCurrentDrawingAppearance takes.
        let draw: () -> Void = { self.item.button?.image = statusMark(state, load: self.load) }
        if let ea = item.button?.effectiveAppearance {
            ea.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        item.button?.toolTip = {
            switch state {
            case .calm: return "Nothing flagged."
            case .holding(let n): return "\(n) process\(n == 1 ? "" : "es") counting towards a rule."
            case .flagged(let n): return "\(n) process\(n == 1 ? "" : "es") flagged."
            }
        }()
    }

    // MARK: - relatives

    private func parentOf(_ p: ProcSample) -> ProcSample? {
        // launchd is everyone's parent eventually and never the answer.
        guard p.ppid > 1 else { return nil }
        return procs.first { $0.pid == p.ppid }
    }

    /// The parents, nearest first, up to launchd. Bounded rather than trusting
    /// the tree: a sample taken while processes are exiting can disagree with
    /// itself, and a cycle here would be a hang.
    private func parentChain(_ p: ProcSample) -> [ProcSample] {
        var out: [ProcSample] = []
        var seen: Set<pid_t> = [p.pid]
        var cur = p
        while out.count < 8, let up = parentOf(cur), !seen.contains(up.pid) {
            out.append(up)
            seen.insert(up.pid)
            cur = up
        }
        return out
    }

    // MARK: - killing

    /// SIGTERM by default, SIGKILL when asked. Checks that the process is the
    /// one that was listed, not a newcomer that has inherited its pid.
    private func killProc(_ p: ProcSample, _ sig: Int32) -> String? {
        switch killability(of: p) {
        case .system:
            return "\(p.name) is part of macOS and is not offered for killing."
        case .zombie:
            return "\(p.name) (\(p.pid)) is already dead and cannot be signalled. "
                 + "Ending its parent is what clears it."
        case .yes:
            break
        }
        guard tracker.stillAlive(p) else { return "\(p.name) (\(p.pid)) has already exited." }
        if kill(p.pid, sig) != 0 {
            let e = errno
            return e == EPERM
                ? "Not permitted to signal \(p.name) (\(p.pid))."
                : "Could not signal \(p.name) (\(p.pid)): \(String(cString: strerror(e)))"
        }
        if termSent[p.pid] == nil { termSent[p.pid] = Date() }
        return nil
    }

    /// The button in a menu row. The menu stays open: the row changes under
    /// the click, then goes on the next sample.
    @objc private func killRow(_ sender: NSButton) {
        guard let row = sender.superview as? ProcessRowView, let p = row.proc,
              let target = row.target else { return }
        let force = termSent[target.pid].map { Date().timeIntervalSince($0) > grace } ?? false
        if let err = killProc(target, force ? SIGKILL : SIGTERM) { row.showError(err); return }
        if let f = verdict.flagged.first(where: { $0.proc.pid == p.pid }) {
            row.show(f, parent: parentOf(p), termSentAt: termSent[target.pid], grace: grace)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 0.3) { [weak self] in self?.refresh() }
    }

    // MARK: - profiles and rules

    /// The one path every rule change takes. A rule whose conditions changed
    /// has to hold for its full sustain again in its own right; one whose name
    /// or sustain changed keeps its clock.
    private func applyProfiles(_ new: [Profile]) {
        var old: [UUID: WatchRule] = [:]
        for r in activeRules { old[r.id] = r }
        profiles = new
        Store.saveProfiles(new)
        let changed = activeRules.filter { r in
            guard let o = old[r.id] else { return true }
            return o.minCPU != r.minCPU || o.minMemoryMB != r.minMemoryMB
                || o.minAgeHours != r.minAgeHours || o.states != r.states
        }.map { $0.id }
        sampleQueue.async { for id in changed { self.tracker.reset(rule: id) } }
        processes?.setProfiles(profiles, active: activeID)
        refresh()
    }

    /// A different profile is a different set of rules, none of which has held
    /// for any time yet, whatever the ones before it had accumulated.
    private func applyActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        Store.saveActive(id)
        sampleQueue.async { self.tracker.resetAll() }
        processes?.setProfiles(profiles, active: id)
        refresh()
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        applyActive(id)
    }

    @objc private func restoreProfiles() {
        let restored = restoringProfiles(profiles)
        applyProfiles(restored)
        if !restored.contains(where: { $0.id == activeID }) { applyActive(defaultProfileID) }
    }

    // MARK: - settings

    /// The one permission this app can want, and it is only ever asked for
    /// here -- when someone turns on the thing that needs it.
    @objc private func toggleInspect() {
        let want = !settings.inspectApps
        if want && !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            alert("Reaper needs Accessibility for this",
                  "Two of the four states -- whether an app has windows, and whether it is "
                  + "answering -- can only be read through the accessibility API, so macOS asks "
                  + "before letting an app read them.\n\n"
                  + "Add Reaper under Privacy & Security \u{2192} Accessibility. Rules that need "
                  + "it will say they are inactive until you do.\n\n"
                  + "The app is ad-hoc signed, so rebuilding it changes its signature and macOS "
                  + "may drop the permission again.")
        }
        settings.inspectApps = want
        Store.saveSettings(settings)
        refresh()
    }

    @objc private func setPoll(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? TimeInterval, s != settings.poll else { return }
        settings.poll = s
        Store.saveSettings(settings)
        startTimer()
        refresh()
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.enabled, appPath: Bundle.main.bundlePath)
        loginItem.state = LoginItem.enabled ? .on : .off
    }

    // MARK: - windows

    @objc private func openProcesses() {
        if processes == nil {
            let w = ProcessWindow(profiles: profiles, active: activeID, showAll: settings.showAll)
            w.onProfilesChanged = { [weak self] new in self?.applyProfiles(new) }
            w.onActiveChanged = { [weak self] id in self?.applyActive(id) }
            w.onKill = { [weak self] p, sig in self?.killProc(p, sig) }
            w.onRefresh = { [weak self] in self?.refresh() }
            w.onDetail = { [weak self] p in self?.openDetail(p) }
            w.onShowAllChanged = { [weak self] on in
                guard let self else { return }
                self.settings.showAll = on
                Store.saveSettings(self.settings)
            }
            processes = w
        }
        processes?.setProfiles(profiles, active: activeID)
        NSApp.activate(ignoringOtherApps: true)
        processes?.showWindow(nil)
        processes?.window?.makeKeyAndOrderFront(nil)
        processes?.update(load: load, procs: procs, verdict: verdict,
                          capability: capability, termSent: termSent)
    }

    private func openDetail(_ p: ProcSample) {
        let w: DetailWindow
        if let existing = details[p.pid], existing.window != nil {
            w = existing
        } else {
            w = DetailWindow(p)
            w.onKill = { [weak self] proc, sig in self?.killProc(proc, sig) }
            w.onRefresh = { [weak self] in self?.refresh() }
            details[p.pid] = w
        }
        let flag = (verdict.flagged + verdict.holding).first { $0.proc.pid == p.pid }
        w.update(p, chain: parentChain(p), flag: flag, trace: tracker.traceFor(p.pid),
                 poll: settings.poll, termSent: termSent[p.pid])
        NSApp.activate(ignoringOtherApps: true)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // Quitting stops the watch, and the mark going is what says so. There is
    // nothing left running behind it: no daemon, no helper, no agent except the
    // login item, which only ever starts this app.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - diagnosis

/// `Reaper --diagnose` prints what the app sees and exits, without putting
/// anything in the menu bar.
///
/// The mark has three states and no text in two of them, which makes "why is it
/// amber" a question a screenshot cannot answer. This prints the answer: which
/// profile is loaded, what the sampler found, and what each rule made of it.
func diagnose() {
    let profiles = Store.loadProfiles()
    let activeID = Store.loadActive(profiles)
    let settings = Store.loadSettings()
    let active = profiles.first { $0.id == activeID }

    print("Reaper \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    print("defaults domain: \(Bundle.main.bundleIdentifier ?? "none -- not running from the bundle")")
    print("profiles:        \(profiles.map { $0.name }.joined(separator: ", "))")
    print("active:          \(active?.name ?? "?")  -- \(active?.detail ?? "")")
    print("poll:            \(Int(settings.poll)) s")
    print("inspect apps:    \(settings.inspectApps)")
    print("login item:      \(LoginItem.enabled)")
    print("")

    let tracker = ProcTracker()
    let gui = guiAppPIDs()
    let (ctx, cap) = liveContext(guiApps: gui, inspectApps: settings.inspectApps)
    _ = tracker.sample(ctx)
    // A second sample a moment later: the first has no interval to divide by,
    // so every CPU figure in it is zero.
    Thread.sleep(forTimeInterval: 2)
    let procs = tracker.sample(ctx)
    let verdict = tracker.evaluate(procs, rules: active?.rules ?? [])

    print("capability:      appsInspected=\(cap.appsInspected)"
          + (cap.reason.isEmpty ? "" : "  (\(cap.reason))"))
    print("sampled:         \(procs.count) processes, \(gui.count) of them apps")
    print("zombies:         \(procs.filter { $0.isZombie }.count)")
    print("orphans:         \(procs.filter { $0.isOrphan }.count)")
    print("")

    print("rules of \(active?.name ?? "?"):")
    for r in active?.rules ?? [] {
        let why = r.inactiveReason(cap)
        print("  \(r.enabled ? "on " : "off") \(r.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
              + " \(r.summary)" + (why == nil ? "" : "   [inactive: \(why!)]"))
    }
    print("")

    print("flagged: \(verdict.flagged.count)")
    for f in verdict.flagged {
        print("  \(f.proc.name) (\(f.proc.pid))  \(fmtCPU(f.proc.cpu))"
              + "  by \(f.rule.name)  held \(fmtAge(f.heldFor))")
    }
    print("counting: \(verdict.holding.count)")
    for h in verdict.holding {
        print("  \(h.proc.name) (\(h.proc.pid))  \(fmtCPU(h.proc.cpu))"
              + "  towards \(h.rule.name)  \(Int(h.progress * 100))% of \(fmtAge(h.rule.sustain))")
    }
    print("")
    let mark = verdict.flagged.isEmpty
        ? (verdict.holding.isEmpty ? "calm" : "holding \(verdict.holding.count)")
        : "flagged \(verdict.flagged.count)"
    print("the mark would be: \(mark)")
}

if CommandLine.arguments.contains("--diagnose") {
    diagnose()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
