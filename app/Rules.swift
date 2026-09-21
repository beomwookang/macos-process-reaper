//
// The rules, the profiles they come in, and where both are kept.
//
// A rule describes a process worth a look. Every condition it sets has to hold,
// and keep holding for its sustain, before the process is flagged: a compiler at
// 800% for forty seconds is doing its job, and the same reading ten minutes
// later is not.
//
// A profile is a whole set of such rules, picked as one. The profile is what you
// choose; the rules under it are what you adjust when the choice is nearly
// right.
//
// Model only, and linked into the test binary: every function that reads
// UserDefaults takes it as a parameter, so nothing here touches the real domain
// unless it is asked to.
//

import Foundation

// MARK: - states

/// A state a process must be in for a rule to hold. The thresholds are
/// numbers; these are the yes/no facts that no number can express. Every state
/// a rule lists has to hold, exactly as every threshold does.
enum WatchState: String, Codable, CaseIterable {
    /// Dead, and its parent has not collected it. Holds nothing and cannot be
    /// signalled -- worth listing so it can be explained, not because it costs
    /// anything.
    case zombie
    /// Adopted by launchd, and not part of macOS.
    case orphan
    /// A GUI app with nothing on screen.
    case windowless
    /// Not answering its accessibility port within the deadline.
    case unresponsive

    /// The word as it appears in a rule's summary and on its checkbox.
    var label: String {
        switch self {
        case .zombie:       return "zombie"
        case .orphan:       return "orphan"
        case .windowless:   return "no window"
        case .unresponsive: return "not responding"
        }
    }

    /// One line, for the tooltip and the detail window. What the state means,
    /// not what to do about it.
    var explanation: String {
        switch self {
        case .zombie:
            return "Dead already. It holds no CPU and no memory and cannot be signalled: "
                 + "it is a row in the process table waiting for its parent to collect it."
        case .orphan:
            return "Its parent died first, so launchd adopted it -- often a background job left "
                 + "behind by a shell that has since closed. On macOS launchd also starts agents "
                 + "and apps directly, so this only means something alongside a threshold."
        case .windowless:
            return "An app meant to have a window, with none on screen -- a viewer still "
                 + "redrawing for a window closed hours ago looks like this. Measured wrong "
                 + "too often to ship: on one machine four of seven apps read as having no "
                 + "windows, Slack and Chrome among them, both of which plainly had several. "
                 + "No profile uses it. Switch it on only after checking, in a detail window, "
                 + "that the window counts for your own apps are right."
        case .unresponsive:
            return "Its main thread is not draining its event queue, so it did not answer "
                 + "in time. This is the state the spinning cursor is showing you."
        }
    }
}

// MARK: - one rule

struct WatchRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    /// Percent of one core, as in `top`. nil = not part of this rule.
    var minCPU: Double?
    /// Megabytes of physical footprint.
    var minMemoryMB: Double?
    /// Hours since the process started.
    var minAgeHours: Double?
    /// Kilobytes written to disk per second. Catches what CPU and memory
    /// cannot see: a log nobody rotates, a sync loop, a process quietly
    /// filling the disk while costing almost nothing to run.
    var minWriteKBs: Double?
    /// Package idle wake-ups per second. The battery condition: a process can
    /// be cheap on CPU and still never let the package idle.
    var minWakeups: Double?
    /// States that must all hold. Empty = the rule is about numbers only.
    var states: Set<WatchState> = []
    /// Seconds the conditions must hold continuously. 0 = flag at once.
    var sustain: TimeInterval = 0

    init(id: UUID = UUID(), name: String, enabled: Bool = true, minCPU: Double? = nil,
         minMemoryMB: Double? = nil, minAgeHours: Double? = nil, minWriteKBs: Double? = nil,
         minWakeups: Double? = nil, states: Set<WatchState> = [], sustain: TimeInterval = 0) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.minCPU = minCPU
        self.minMemoryMB = minMemoryMB
        self.minAgeHours = minAgeHours
        self.minWriteKBs = minWriteKBs
        self.minWakeups = minWakeups
        self.states = states
        self.sustain = sustain
    }

    /// Declared rather than synthesised: this type customises both halves of
    /// Codable, and the compiler only writes these keys for a type that leaves
    /// one of them alone.
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, minCPU, minMemoryMB, minAgeHours, minWriteKBs, minWakeups,
             states, sustain
    }

    /// Every key is optional on the way in, so a rules file written by a
    /// version with fewer fields still loads rather than wiping the list. An
    /// unknown state string is dropped rather than failing the whole rule, for
    /// the same reason in the other direction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Rule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minCPU = try c.decodeIfPresent(Double.self, forKey: .minCPU)
        minMemoryMB = try c.decodeIfPresent(Double.self, forKey: .minMemoryMB)
        minAgeHours = try c.decodeIfPresent(Double.self, forKey: .minAgeHours)
        minWriteKBs = try c.decodeIfPresent(Double.self, forKey: .minWriteKBs)
        minWakeups = try c.decodeIfPresent(Double.self, forKey: .minWakeups)
        let raw = try c.decodeIfPresent([String].self, forKey: .states) ?? []
        states = Set(raw.compactMap(WatchState.init(rawValue:)))
        sustain = try c.decodeIfPresent(TimeInterval.self, forKey: .sustain) ?? 0
    }

    /// Encoded as a sorted array rather than a set, so two equal rules produce
    /// the same bytes and a diff of the stored defaults stays readable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(minCPU, forKey: .minCPU)
        try c.encodeIfPresent(minMemoryMB, forKey: .minMemoryMB)
        try c.encodeIfPresent(minAgeHours, forKey: .minAgeHours)
        try c.encodeIfPresent(minWriteKBs, forKey: .minWriteKBs)
        try c.encodeIfPresent(minWakeups, forKey: .minWakeups)
        try c.encode(states.map { $0.rawValue }.sorted(), forKey: .states)
        try c.encode(sustain, forKey: .sustain)
    }

    /// A rule with nothing set matches nothing, not everything.
    var isEmpty: Bool {
        minCPU == nil && minMemoryMB == nil && minAgeHours == nil
            && minWriteKBs == nil && minWakeups == nil && states.isEmpty
    }

    func holds(for p: ProcSample) -> Bool {
        guard !isEmpty else { return false }
        if let c = minCPU, p.cpu < c { return false }
        if let m = minMemoryMB, Double(p.memory) / 1_048_576 < m { return false }
        if let h = minAgeHours, p.age / 3600 < h { return false }
        if let w = minWriteKBs, p.writeRate / 1024 < w { return false }
        if let k = minWakeups, p.wakeupRate < k { return false }
        for s in states {
            switch s {
            case .zombie: if !p.isZombie { return false }
            case .orphan: if !p.isOrphan { return false }
            // Unknown is not a match. A rule that needs the window server, or
            // the hang probe, flags nothing while it cannot see -- it does not
            // flag everything.
            case .windowless: if p.isWindowless != true { return false }
            case .unresponsive: if p.responsive != false { return false }
            }
        }
        return true
    }

    /// The rule as a phrase, for the row that says why a process is listed.
    /// States first: "zombie" is the headline, and "CPU >= 0%" never is.
    var summary: String {
        var bits: [String] = WatchState.allCases.filter { states.contains($0) }.map { $0.label }
        if let c = minCPU { bits.append("CPU \u{2265} \(fmtNum(c))%") }
        if let m = minMemoryMB { bits.append("mem \u{2265} \(fmtBytes(UInt64(m * 1_048_576)))") }
        if let h = minAgeHours { bits.append("age \u{2265} \(fmtNum(h)) h") }
        if let w = minWriteKBs { bits.append("write \u{2265} \(fmtRate(w * 1024))") }
        if let k = minWakeups { bits.append("wakeups \u{2265} \(fmtNum(k))/s") }
        if bits.isEmpty { return "nothing set" }
        if sustain > 0 { bits.append("for \(fmtAge(sustain))") }
        return bits.joined(separator: " \u{00B7} ")
    }

    /// Whether this rule depends on apps being asked about themselves. Both
    /// states that do come from the same accessibility call, so one accessor
    /// covers both.
    var needsInspection: Bool {
        states.contains(.windowless) || states.contains(.unresponsive)
    }

    /// Why this rule cannot currently flag anything, or nil when it can. A rule
    /// that has been switched on and is quietly unable to see has to say so:
    /// silence from a watchdog is meant to mean "nothing is wrong".
    func inactiveReason(_ cap: WatchCapability) -> String? {
        if !enabled { return nil }
        if isEmpty { return "nothing set" }
        if needsInspection && !cap.appsInspected { return cap.reason }
        return nil
    }
}

// MARK: - profiles

/// A named set of rules, picked as a whole.
///
/// Whole sets rather than diffs, so picking one cannot leave half of the last
/// one behind. `builtIn` marks the three that ship: they can be edited like any
/// other, and Restore Profiles puts them back as shipped.
struct Profile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// One lowercase phrase, used as the menu suffix and the tooltip.
    var detail: String
    var rules: [WatchRule]
    var builtIn = false

    init(id: UUID = UUID(), name: String, detail: String, rules: [WatchRule], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.rules = rules
        self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        rules = try c.decodeIfPresent([WatchRule].self, forKey: .rules) ?? []
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

/// Identifiers are fixed rather than fresh, so the profile a user picked is
/// still the one selected after a relaunch, and so a shipped profile can be
/// recognised across versions even after it has been renamed.
private func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }

/// The profiles a fresh install starts with, and what Restore Profiles brings
/// back. Three points on one trade: how much you want to be told.
///
/// The numbers are a starting point, not a measurement. They are the shapes of
/// forgotten process, sized so that ordinary work -- a build, an export, an
/// indexing pass -- does not trip them; tune them against your own machine.
let builtInProfiles: [Profile] = [
    Profile(id: uuid("A0000000-0000-4000-8000-000000000001"),
            name: "Quiet", detail: "only what is unmistakable",
            rules: [
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000101"),
                          name: "Runaway", minCPU: 500, sustain: 600),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000102"),
                          name: "Memory hog", minMemoryMB: 8192, sustain: 300),
            ],
            builtIn: true),
    // Quiet and Balanced ask for nothing the app is not already allowed to see,
    // so they work on a machine that has granted no permission at all. Only
    // Aggressive uses the two states that need Accessibility.
    Profile(id: uuid("A0000000-0000-4000-8000-000000000002"),
            name: "Balanced", detail: "runaways, hogs and orphans",
            rules: [
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000201"),
                          name: "Runaway", minCPU: 300, sustain: 300),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000202"),
                          name: "Busy for hours", minCPU: 50, minAgeHours: 12, sustain: 600),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000203"),
                          name: "Memory hog", minMemoryMB: 4096, sustain: 60),
                // A full core, for an hour, with no parent and not part of
                // macOS. Anything less than that flags the crashpad handlers
                // and XPC services launchd legitimately parents.
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000205"),
                          name: "Orphan", minCPU: 100, minAgeHours: 1,
                          states: [.orphan], sustain: 300),
            ],
            builtIn: true),
    Profile(id: uuid("A0000000-0000-4000-8000-000000000003"),
            name: "Aggressive", detail: "everything, sooner",
            rules: [
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000301"),
                          name: "Runaway", minCPU: 200, sustain: 120),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000302"),
                          name: "Busy for hours", minCPU: 30, minAgeHours: 6, sustain: 300),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000303"),
                          name: "Memory hog", minMemoryMB: 2048, sustain: 30),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000305"),
                          name: "Orphan", minCPU: 50, minAgeHours: 0.5,
                          states: [.orphan], sustain: 120),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000306"),
                          name: "Not responding", states: [.unresponsive], sustain: 60),
                WatchRule(id: uuid("B0000000-0000-4000-8000-000000000307"),
                          name: "Zombie", states: [.zombie], sustain: 0),
            ],
            builtIn: true),
]

let defaultProfileID = builtInProfiles[1].id

/// The list with each shipped profile put back as shipped: an edited one
/// replaced, a deleted one re-added in its original position, profiles of the
/// user's own left alone.
///
/// Matched on identifier rather than name, so renaming a shipped profile does
/// not turn it into a second one.
func restoringProfiles(_ profiles: [Profile]) -> [Profile] {
    var out = profiles
    for (i, p) in builtInProfiles.enumerated() {
        if let j = out.firstIndex(where: { $0.id == p.id }) {
            out[j] = p
        } else {
            out.insert(p, at: min(i, out.count))
        }
    }
    return out
}

// MARK: - settings

struct WatchSettings: Codable, Equatable {
    /// Seconds between samples. The CPU figure is the average over one
    /// interval, so a longer poll is a smoother reading as well as a cheaper
    /// one; it is also a coarser sustain clock.
    var poll: TimeInterval = 5
    /// Ask each app about its windows and whether it is answering. Needs
    /// Accessibility, so it stays off until it is asked for, and the two states
    /// that depend on it say so meanwhile.
    var inspectApps = false
    /// The window's table opens on everything rather than on what is flagged.
    var showAll = false
    /// The rule editor is open. Closed by default: once a profile is picked
    /// the numbers under it are rarely touched, and nine rules at two lines
    /// each make a window taller than a laptop screen.
    var rulesOpen = false
    /// Watching is suspended until this moment. For deliberately running
    /// something that would trip every rule -- a long build, a big export --
    /// without turning the rules off and forgetting to turn them back on.
    var pausedUntil: Date?
    /// Post a notification the first time a process is flagged. Off by
    /// default: the mark is the alert, and this is for the times the menu bar
    /// is not on screen at all.
    var notify = false

    static let pollChoices: [TimeInterval] = [2, 5, 10, 30]
    /// How long Pause lasts, and what the menu offers.
    static let pauseChoices: [TimeInterval] = [15 * 60, 60 * 60, 4 * 3600]

    /// Whether watching is suspended right now. A pause that has run out is
    /// simply over -- nothing has to clear it.
    func paused(_ now: Date = Date()) -> Bool {
        guard let until = pausedUntil else { return false }
        return until > now
    }

    /// Declared rather than synthesised, because `probeHangs` is a key that is
    /// read and never written: it is the old name of `inspectApps`.
    private enum CodingKeys: String, CodingKey {
        case poll, inspectApps, showAll, probeHangs, pausedUntil, notify, rulesOpen
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(poll, forKey: .poll)
        try c.encode(inspectApps, forKey: .inspectApps)
        try c.encode(showAll, forKey: .showAll)
        try c.encode(rulesOpen, forKey: .rulesOpen)
        try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        try c.encode(notify, forKey: .notify)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        poll = try c.decodeIfPresent(TimeInterval.self, forKey: .poll) ?? 5
        // `probeHangs` is what this switch was called when it only drove the
        // hang probe, before the same call turned out to answer the window
        // question too. Read so an early settings file keeps its choice.
        inspectApps = try c.decodeIfPresent(Bool.self, forKey: .inspectApps)
            ?? c.decodeIfPresent(Bool.self, forKey: .probeHangs) ?? false
        showAll = try c.decodeIfPresent(Bool.self, forKey: .showAll) ?? false
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        rulesOpen = try c.decodeIfPresent(Bool.self, forKey: .rulesOpen) ?? false
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        // A stored poll from a future version, or a hand-edited zero, would
        // otherwise become a timer that fires continuously.
        if !WatchSettings.pollChoices.contains(poll) {
            poll = min(max(poll, 1), 300)
        }
        // A pause from a previous run is honoured, but not one that would
        // outlast any pause this app offers: a hand-edited date in 2099 would
        // otherwise switch the watch off for ever and look like a bug.
        if let until = pausedUntil,
           until > Date().addingTimeInterval(WatchSettings.pauseChoices.max() ?? 3600) {
            pausedUntil = nil
        }
    }
}

// MARK: - storage

/// Everything lives in the app's own defaults: it is the app's concern alone,
/// and nothing else has to parse it. UserDefaults is a parameter with a default
/// so persistence can be checked against a suite of its own.
enum Store {
    static let profilesKey   = "profiles"
    static let activeKey     = "activeProfile"
    static let settingsKey   = "settings"
    static let exclusionsKey = "exclusions"
    static let historyKey    = "history"

    static func loadProfiles(_ d: UserDefaults = .standard) -> [Profile] {
        guard let data = d.data(forKey: profilesKey),
              let ps = try? JSONDecoder().decode([Profile].self, from: data),
              !ps.isEmpty else {
            return builtInProfiles
        }
        return ps
    }

    static func saveProfiles(_ ps: [Profile], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(ps) { d.set(data, forKey: profilesKey) }
    }

    /// The identifier of the active profile, or the default when what was
    /// stored no longer exists -- a profile deleted in one version must not
    /// leave the next one with no rules at all.
    static func loadActive(_ profiles: [Profile], _ d: UserDefaults = .standard) -> UUID {
        if let s = d.string(forKey: activeKey), let id = UUID(uuidString: s),
           profiles.contains(where: { $0.id == id }) {
            return id
        }
        if profiles.contains(where: { $0.id == defaultProfileID }) { return defaultProfileID }
        return profiles.first?.id ?? defaultProfileID
    }

    static func saveActive(_ id: UUID, _ d: UserDefaults = .standard) {
        d.set(id.uuidString, forKey: activeKey)
    }

    static func loadSettings(_ d: UserDefaults = .standard) -> WatchSettings {
        guard let data = d.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(WatchSettings.self, from: data) else {
            return WatchSettings()
        }
        return s
    }

    static func saveSettings(_ s: WatchSettings, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: settingsKey) }
    }

    static func loadExclusions(_ d: UserDefaults = .standard) -> [Exclusion] {
        guard let data = d.data(forKey: exclusionsKey),
              let x = try? JSONDecoder().decode([Exclusion].self, from: data) else { return [] }
        // An entry with no path can never match anything, so it is only clutter.
        return x.filter { !$0.appPath.isEmpty }
    }

    static func saveExclusions(_ x: [Exclusion], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(x) { d.set(data, forKey: exclusionsKey) }
    }

    /// The history survives a relaunch, which is the point of keeping it: the
    /// question it answers is about a time you were not watching, and that
    /// includes times the app was not running.
    static func loadHistory(_ d: UserDefaults = .standard) -> FlagLog {
        guard let data = d.data(forKey: historyKey),
              let e = try? JSONDecoder().decode([FlagEvent].self, from: data) else {
            return FlagLog()
        }
        // Anything still open was open when the app last stopped. It cannot be
        // known to be open now, so it is closed at the last tick that saw it
        // rather than left to look current.
        var log = FlagLog(events: e)
        log.closeOpen()
        return log
    }

    static func saveHistory(_ log: FlagLog, _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(log.events) { d.set(data, forKey: historyKey) }
    }
}
