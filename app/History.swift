//
// What was flagged, and what is never to be flagged.
//
// The app was otherwise instantaneous: it knew what was wrong now and forgot it
// the moment the process exited. That leaves the question it was built for --
// "my Mac was hot an hour ago, what was it?" -- unanswered for anyone who was
// not looking at the menu bar at the time, which is most of the time.
//
// The exclusions are the other half of being kept switched on. A forty-minute
// video export trips a busy-for-hours rule honestly, and without a way to say
// "not this one" the only remedy is to switch the rule off, which loses the
// detection instead of narrowing it.
//
// Model only, and linked into the test binary: the clock is a parameter
// everywhere it matters.
//

import Foundation

// MARK: - exclusions

/// An app never to flag.
///
/// Written against the bundle rather than the executable: excluding a browser
/// has to exclude the six helpers it will start next, and they all live inside
/// the same bundle.
struct Exclusion: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The app bundle's path, or the executable's for something with no bundle.
    var appPath: String
    /// What to call it in the list.
    var name: String
    var added = Date()

    init(id: UUID = UUID(), appPath: String, name: String, added: Date = Date()) {
        self.id = id
        self.appPath = appPath
        self.name = name
        self.added = added
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
    }

    /// The exclusion a process would produce. nil for anything with no path to
    /// write one against, which is every zombie.
    init?(_ p: ProcSample) {
        guard !p.appPath.isEmpty else { return nil }
        self.init(appPath: p.appPath, name: p.appName)
    }
}

/// The set `evaluate` takes. A set rather than the list, because matching runs
/// once per process per tick and the list is a list so it can keep its order.
func excludedPaths(_ list: [Exclusion]) -> Set<String> {
    Set(list.map { $0.appPath }.filter { !$0.isEmpty })
}

// MARK: - history

/// One process's run of being flagged, kept after it has gone.
///
/// Identity is the process and the rule together: the same process flagged
/// again by a different rule is a different thing to have happened, and the
/// same process flagged again after a gap is too, which is why the key
/// includes when it began.
struct FlagEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var appPath: String
    var pid: pid_t
    /// The process's start time, so a reused pid cannot extend someone else's
    /// entry.
    var startedMicros: UInt64
    var rule: String
    var summary: String
    /// When the rule's conditions first held, not when the sustain elapsed.
    var began: Date
    /// The last tick it was still flagged.
    var lastSeen: Date
    /// Set once, when it stops being flagged.
    var ended: Date?
    var peakCPU: Double
    var peakMemory: UInt64
    var peakWriteRate: Double
    var wasZombie: Bool
    /// Whether a signal went out from this app while it was listed. Recorded
    /// because "it went away" and "I ended it" are different answers to what
    /// happened.
    var signalled = false

    var key: String { "\(pid)/\(startedMicros)/\(rule)" }

    /// How long it was flagged for, ending now if it still is.
    func duration(_ now: Date = Date()) -> TimeInterval {
        (ended ?? max(lastSeen, now)).timeIntervalSince(began)
    }

    init(_ f: ProcTracker.Flag, now: Date) {
        name = f.proc.name
        appPath = f.proc.appPath
        pid = f.proc.pid
        startedMicros = f.proc.startedMicros
        rule = f.rule.name
        summary = f.rule.summary
        began = now.addingTimeInterval(-f.heldFor)
        lastSeen = now
        peakCPU = f.proc.cpu
        peakMemory = f.proc.memory
        peakWriteRate = f.proc.writeRate
        wasZombie = f.proc.isZombie
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        pid = try c.decodeIfPresent(pid_t.self, forKey: .pid) ?? 0
        startedMicros = try c.decodeIfPresent(UInt64.self, forKey: .startedMicros) ?? 0
        rule = try c.decodeIfPresent(String.self, forKey: .rule) ?? "?"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        began = try c.decodeIfPresent(Date.self, forKey: .began) ?? Date()
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? began
        ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        peakCPU = try c.decodeIfPresent(Double.self, forKey: .peakCPU) ?? 0
        peakMemory = try c.decodeIfPresent(UInt64.self, forKey: .peakMemory) ?? 0
        peakWriteRate = try c.decodeIfPresent(Double.self, forKey: .peakWriteRate) ?? 0
        wasZombie = try c.decodeIfPresent(Bool.self, forKey: .wasZombie) ?? false
        signalled = try c.decodeIfPresent(Bool.self, forKey: .signalled) ?? false
    }
}

/// The log. Newest first, bounded, and told about each tick's flags.
struct FlagLog: Equatable {
    /// Newest first, so the window shows the last thing that happened without
    /// reversing anything and pruning drops the oldest.
    private(set) var events: [FlagEvent] = []
    /// Enough to answer "what happened this morning" without becoming a
    /// database. At the shipped poll this is many hours of distinct flags.
    var limit = 200

    init(events: [FlagEvent] = [], limit: Int = 200) {
        self.events = events
        self.limit = limit
    }

    /// Folds one tick's flags in. Returns the events that are new, so the
    /// caller can decide whether any of them is worth telling someone about --
    /// once, when it starts, rather than every tick while it lasts.
    @discardableResult
    mutating func record(_ flags: [ProcTracker.Flag], now: Date = Date()) -> [FlagEvent] {
        var fresh: [FlagEvent] = []
        var live = Set<String>()
        for f in flags {
            let e = FlagEvent(f, now: now)
            live.insert(e.key)
            if let i = events.firstIndex(where: { $0.key == e.key && $0.ended == nil }) {
                events[i].lastSeen = now
                events[i].peakCPU = max(events[i].peakCPU, f.proc.cpu)
                events[i].peakMemory = max(events[i].peakMemory, f.proc.memory)
                events[i].peakWriteRate = max(events[i].peakWriteRate, f.proc.writeRate)
            } else {
                events.insert(e, at: 0)
                fresh.append(e)
            }
        }
        // Anything open that this tick did not see has stopped being flagged --
        // it exited, or it dropped below the rule, or the rule changed.
        for i in events.indices where events[i].ended == nil && !live.contains(events[i].key) {
            events[i].ended = events[i].lastSeen
        }
        if events.count > limit { events.removeLast(events.count - limit) }
        return fresh
    }

    /// Notes that a signal went out, so the entry says what happened to it
    /// rather than only that it stopped.
    mutating func markSignalled(pid: pid_t, startedMicros: UInt64) {
        for i in events.indices
        where events[i].pid == pid && events[i].startedMicros == startedMicros {
            events[i].signalled = true
        }
    }

    /// Everything still being flagged this moment.
    var open: [FlagEvent] { events.filter { $0.ended == nil } }

    mutating func clear() { events = [] }

    /// Closes every open entry at the last tick that saw it. Used when the log
    /// is read back from a previous run, where "still flagged" means "was still
    /// flagged when the app stopped" and must not be shown as current.
    mutating func closeOpen() {
        for i in events.indices where events[i].ended == nil {
            events[i].ended = events[i].lastSeen
        }
    }
}
