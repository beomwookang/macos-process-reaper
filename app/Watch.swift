//
// The sampler: every process this user owns, and what the rules make of them.
//
// The processes worth naming are the ones nobody remembers starting -- a
// headless browser a script left behind, a build that never finished, a viewer
// redrawing at full tilt for a window closed hours ago -- and the ones that are
// simply broken: dead but uncollected, orphaned, or hung. The first kind is
// described by numbers held over time; the second by states no number can
// express. This file gathers both and hands them to the rules.
//
// Model only. The windows are elsewhere. This file is linked into the test
// binary, so nothing in it may open a window or read UserDefaults on its own
// account, and everything it cannot get from the kernel is injected.
//

import AppKit
import ApplicationServices
import Foundation
import IOKit

// MARK: - one process

struct ProcSample {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    /// Executable path. Empty when the kernel would not say, which is always
    /// the case for a zombie: the path is read from the address space, and a
    /// zombie no longer has one.
    let path: String
    /// Percent of one core over the last sampling interval, counted as `top`
    /// counts it: 100 is one core busy, 800 is eight. Zero on the first sample,
    /// when there is no interval yet, and zero for a zombie, which runs nothing.
    let cpu: Double
    /// Physical footprint in bytes -- the figure Activity Monitor calls Memory.
    let memory: UInt64
    /// Bytes written to disk per second over the last interval. Zero on the
    /// first sample and for a zombie, as with CPU.
    let writeRate: Double
    /// Bytes read from disk per second. Reported, not a rule condition: a
    /// process reading hard is usually doing its job, where one writing hard
    /// for hours usually is not.
    let readRate: Double
    /// Package idle wake-ups per second -- the figure behind Activity Monitor's
    /// energy impact. A process can be cheap on CPU and still ruin a battery by
    /// never letting the package idle.
    let wakeupRate: Double
    /// Seconds since the process started, by the wall clock.
    let age: TimeInterval
    /// Start time in microseconds since the epoch, from the kernel's BSD info.
    /// Together with the pid this identifies a process: pids are reused, start
    /// times are not. Identity hangs off this rather than the mach-absolute
    /// figure rusage reports, because rusage refuses to answer for a zombie and
    /// the BSD info still does.
    let startedMicros: UInt64
    /// Dead, and not yet collected by its parent.
    let isZombie: Bool
    /// Meant to have a user interface: a regular activation policy, as opposed
    /// to a helper or an agent that was never going to show a window.
    let isGUIApp: Bool
    /// On-screen windows it owns. nil when the window server was not asked, or
    /// would not answer.
    let windows: Int?
    /// nil when the hang probe is off, or this process was not one it reached.
    let responsive: Bool?

    var started: TimeInterval { Double(startedMicros) / 1e6 }

    /// The app bundle this executable belongs to, or the executable itself.
    ///
    /// The unit an exclusion is written against: excluding a browser has to
    /// exclude the six helpers it will start next, and they all live inside the
    /// same bundle. Empty for a zombie, which has no path left, so an exclusion
    /// can never match one by accident.
    var appPath: String {
        guard !path.isEmpty else { return "" }
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path
    }

    /// What to call the thing an exclusion is written against.
    var appName: String {
        let a = appPath
        guard !a.isEmpty else { return name }
        return a.hasSuffix(".app")
            ? ((a as NSString).lastPathComponent as NSString).deletingPathExtension
            : (a as NSString).lastPathComponent
    }

    /// Adopted by launchd, and not part of macOS.
    ///
    /// The `ppid == 1` half is the textbook definition and, on its own, close to
    /// useless here: launchd is the direct parent of every LaunchAgent and every
    /// app the Dock starts, so it reads as the normal state rather than as a
    /// process that lost its parent. Measured on one machine: 438 of 496 of the
    /// user's processes had ppid 1. Excluding what macOS itself ships brings
    /// that to 40, which is a signal worth combining with a threshold.
    ///
    /// A controlling terminal looked like the better discriminator -- a job left
    /// behind by a shell keeps its tty where an agent never had one -- but the
    /// tty is revoked when the terminal goes, so it reads as NODEV for exactly
    /// the processes it was meant to find. Measured: zero of the 438.
    var isOrphan: Bool { pid != 1 && ppid == 1 && !isSystem }

    /// A GUI app with nothing on screen -- the shape of a viewer still redrawing
    /// for a window closed hours ago. nil rather than false when the window
    /// count is unknown, so a rule can never match on an absence of information.
    var isWindowless: Bool? {
        guard isGUIApp else { return false }
        return windows.map { $0 == 0 }
    }

    /// Part of macOS rather than something the user launched. Listed, but not
    /// offered for killing: ending loginwindow logs you out, and the rest
    /// respawn, so the button would either do harm or nothing.
    var isSystem: Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/")
            || path.hasPrefix("/Library/Apple/")
            || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/"))
    }

    init(pid: pid_t, ppid: pid_t, name: String, path: String, cpu: Double, memory: UInt64,
         age: TimeInterval, startedMicros: UInt64, writeRate: Double = 0, readRate: Double = 0,
         wakeupRate: Double = 0, isZombie: Bool = false,
         isGUIApp: Bool = false, windows: Int? = nil, responsive: Bool? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.cpu = cpu
        self.memory = memory
        self.writeRate = writeRate
        self.readRate = readRate
        self.wakeupRate = wakeupRate
        self.age = age
        self.startedMicros = startedMicros
        self.isZombie = isZombie
        self.isGUIApp = isGUIApp
        self.windows = windows
        self.responsive = responsive
    }
}

// MARK: - what the kernel does not know

/// The facts that do not come from the kernel's proc tables: which pids are
/// apps at all, how many windows each has, and which are not answering.
///
/// Injected rather than looked up inside the sampler, so the rules can be
/// checked without a window server or an accessibility grant. CI runners have
/// neither, and a test that depends on one is a test that fails in CI for no
/// reason.
struct ProcContext {
    var guiApps: Set<pid_t> = []
    /// Windows per app, for the apps in `probed`. Absent for an app that did
    /// not answer, because a hung app cannot be asked either.
    var windows: [pid_t: Int] = [:]
    /// Of the pids in `probed`, the ones that did not answer in time.
    var unresponsive: Set<pid_t> = []
    /// The pids actually asked. A pid outside this set reads as unknown, never
    /// as responsive or as having no windows.
    var probed: Set<pid_t> = []

    init(guiApps: Set<pid_t> = [], windows: [pid_t: Int] = [:],
         unresponsive: Set<pid_t> = [], probed: Set<pid_t> = []) {
        self.guiApps = guiApps
        self.windows = windows
        self.unresponsive = unresponsive
        self.probed = probed
    }
}

/// What the app can currently see. A rule asking for something unavailable has
/// to say so rather than quietly flagging nothing: silence from a watchdog is
/// meant to mean "nothing is wrong".
struct WatchCapability {
    /// Whether apps are being asked about their windows and their
    /// responsiveness. Both answers come from the same accessibility call, so
    /// they stand or fall together.
    var appsInspected = false
    /// Why they are not, when they are not.
    var reason = "window and responsiveness checks are off"
}

// MARK: - the machine as a whole

struct SystemLoad {
    /// Fraction of all cores busy since the previous sample. nil until there
    /// is a previous sample.
    var cpu: Double?
    var ncpu: Int
    /// Percent, system-wide. nil where the driver does not report it.
    var gpu: Double?
    var memUsed: UInt64
    var memTotal: UInt64
}

// MARK: - killing

/// Whether a process may be signalled, and why not when it may not. One pure
/// answer, so the menu row and the window can never disagree about a button.
enum Killable: Equatable {
    case yes
    /// Part of macOS: listed, never offered.
    case system
    /// Already dead. A zombie holds no CPU and no memory and cannot be
    /// signalled -- it is a row in the process table waiting for its parent to
    /// collect it, so the parent is the thing to end.
    case zombie(parent: pid_t?)
}

func killability(of p: ProcSample) -> Killable {
    if p.isZombie { return .zombie(parent: p.ppid > 1 ? p.ppid : nil) }
    if p.isSystem { return .system }
    return .yes
}

/// What a row's one button should signal: the process itself; or its parent,
/// when the process is a zombie and ending the parent is the only thing that
/// clears it; or nothing, when neither can be touched.
///
/// This is why the button on a zombie's row acts on something other than the
/// row it is in. The alternative is a button that is always disabled on exactly
/// the rows a person most wants to do something about.
func killTarget(_ p: ProcSample, parent: ProcSample?) -> ProcSample? {
    switch killability(of: p) {
    case .yes:
        return p
    case .system:
        return nil
    case .zombie:
        guard let parent, !parent.isZombie else { return nil }
        // A zombie parented by something macOS owns is a dead end: the parent
        // cannot be signalled, so nothing here will collect the child.
        return parent.isSystem ? nil : parent
    }
}

// MARK: - sampling

/// Samples every process the user owns, and keeps the little state that turns
/// two samples into a CPU percentage and a run of samples into "sustained".
///
/// Only the user's own processes: the kernel refuses task information on
/// anyone else's without root, and the app has none. Those it could not judge
/// it also could not kill, so nothing usable is lost by not listing them.
final class ProcTracker {
    /// `at` is mach absolute, for the CPU ratio, which is in the same units.
    /// `atWall` is seconds, for the byte and wake-up rates, which are counts
    /// and need a real interval to divide by.
    private struct Prev {
        let started: UInt64
        let cpuTime: UInt64
        let at: UInt64
        let atWall: TimeInterval
        let written: UInt64
        let read: UInt64
        let wakeups: UInt64
    }
    private var prev: [pid_t: Prev] = [:]

    /// When each (process, rule) pair first started holding, keyed so that a
    /// reused pid or an edited rule starts the clock afresh.
    private var since: [String: Date] = [:]

    /// A short CPU trace per process, oldest first, for the detail window's
    /// sparkline. Kept for everything sampled rather than only for what is
    /// flagged: a process is interesting to look at before a rule agrees, and
    /// at this cap the whole table costs well under a megabyte.
    private var trace: [pid_t: [Double]] = [:]
    private let traceMax = 120

    private var prevHost: (busy: UInt64, total: UInt64)?

    private let uid = getuid()
    private let me = getpid()
    private let tbNumer: Double, tbDenom: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tbNumer = Double(tb.numer)
        tbDenom = Double(tb.denom)
    }

    func sample(_ ctx: ProcContext = ProcContext()) -> [ProcSample] {
        let nowMach = mach_absolute_time()
        let nowWall = Date().timeIntervalSince1970
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // A little headroom: processes can appear between the count and the list.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var out: [ProcSample] = []
        var next: [pid_t: Prev] = [:]
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)

        for pid in pids.prefix(Int(max(got, 0))) where pid > 1 && pid != me {
            // BSD info first: it is refused for other users' processes, which is
            // the cheap way to skip them, and it is the only thing the kernel
            // will still say about a zombie.
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else {
                // A zombie is refused here. Measured: PROC_PIDTBSDINFO returns
                // ESRCH, and so does PROC_PIDT_SHORTBSDINFO, for a pid
                // proc_listallpids had just handed over -- the task is gone and
                // both flavours read the task. sysctl still answers, which is
                // how ps manages to print them at all.
                //
                // Only on failure, with the uid checked after, so the reason
                // for coming here is always "the kernel would not describe it"
                // and never "it belongs to someone else".
                //
                // It costs a wasted sysctl per foreign process, because this
                // call is refused for those too: measured, 290 of 786 pids, and
                // zombieSample rejects each on its uid. Measured cost of a whole
                // sample with them in it: 3.9 ms for 484 processes, of which a
                // sysctl is the dearest call at roughly 9 us against 2 us for
                // the others. If that ever matters, the fix is one
                // sysctl(KERN_PROC_ALL) for the whole table instead of a
                // per-pid fallback -- not a cheaper way to ask about one pid,
                // because there is not one.
                if let z = Self.zombieSample(pid, uid: uid, now: nowWall) { out.append(z) }
                continue
            }
            guard bsd.pbi_uid == uid else { continue }

            let zombie = bsd.pbi_status == UInt32(SZOMB)
            let started = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            let age = max(0, nowWall - Double(started) / 1e6)
            let isGUI = ctx.guiApps.contains(pid)
            // Unknown unless this app was actually asked. An app that was asked
            // and did not answer has an unknown window count too: the same call
            // would have carried both.
            let responsive: Bool? = ctx.probed.contains(pid) ? !ctx.unresponsive.contains(pid) : nil
            let windows: Int? = ctx.probed.contains(pid) ? ctx.windows[pid] : nil

            if zombie {
                // rusage answers for a live task, and a zombie has none: its
                // address space is already gone, which is why there is no path
                // and no footprint to report. The BSD name is all that is left.
                out.append(ProcSample(pid: pid, ppid: pid_t(bsd.pbi_ppid),
                                      name: Self.bsdName(&bsd), path: "",
                                      cpu: 0, memory: 0, age: age, startedMicros: started,
                                      isZombie: true, isGUIApp: isGUI,
                                      windows: windows, responsive: responsive))
                continue
            }

            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }

            // CPU time and wall time are both in mach absolute units, so the
            // ratio needs no conversion. Only against a previous sample of the
            // same process: a pid that has been reused since has a new start.
            let cpuTime = ru.ri_user_time + ru.ri_system_time
            var cpu = 0.0
            var writeRate = 0.0, readRate = 0.0, wakeupRate = 0.0
            if let p = prev[pid], p.started == started {
                if nowMach > p.at, cpuTime >= p.cpuTime {
                    cpu = Double(cpuTime - p.cpuTime) / Double(nowMach - p.at) * 100
                }
                // Cumulative counters, so a rate needs the interval. Guarded
                // against going backwards: the kernel resets these on exec, and
                // a negative rate would read as a suspiciously quiet process
                // rather than as nonsense.
                let dt = nowWall - p.atWall
                if dt > 0.05 {
                    writeRate = rate(ru.ri_diskio_byteswritten, p.written, dt)
                    readRate = rate(ru.ri_diskio_bytesread, p.read, dt)
                    wakeupRate = rate(ru.ri_pkg_idle_wkups, p.wakeups, dt)
                }
            }
            next[pid] = Prev(started: started, cpuTime: cpuTime, at: nowMach, atWall: nowWall,
                             written: ru.ri_diskio_byteswritten, read: ru.ri_diskio_bytesread,
                             wakeups: ru.ri_pkg_idle_wkups)

            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
            let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
            let name = path.isEmpty ? Self.bsdName(&bsd) : (path as NSString).lastPathComponent

            out.append(ProcSample(pid: pid, ppid: pid_t(bsd.pbi_ppid), name: name, path: path,
                                  cpu: cpu, memory: ru.ri_phys_footprint, age: age,
                                  startedMicros: started, writeRate: writeRate,
                                  readRate: readRate, wakeupRate: wakeupRate,
                                  isZombie: false, isGUIApp: isGUI,
                                  windows: windows, responsive: responsive))
        }
        prev = next
        recordTrace(out)
        return out
    }

    /// A zombie, read the only way the kernel will still describe one: the
    /// process table entry, which outlives the task.
    ///
    /// nil for anything that is not a zombie of this user's -- which includes a
    /// process that merely exited between the listing and the query, the other
    /// reason the BSD info call fails.
    private static func zombieSample(_ pid: pid_t, uid: uid_t, now: TimeInterval) -> ProcSample? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var ki = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &ki, &len, nil, 0) == 0, len > 0,
              ki.kp_proc.p_stat == SZOMB,
              ki.kp_eproc.e_ucred.cr_uid == uid else { return nil }

        let name = withUnsafePointer(to: &ki.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let start = ki.kp_proc.p_starttime
        let started = UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
        // No path, no footprint and no CPU: the address space they would be read
        // from is already gone. That absence is the fact, not a missing reading.
        return ProcSample(pid: pid, ppid: ki.kp_eproc.e_ppid, name: name, path: "",
                          cpu: 0, memory: 0, age: max(0, now - Double(started) / 1e6),
                          startedMicros: started, isZombie: true)
    }

    /// A per-second rate from two readings of a counter that only goes up.
    private func rate(_ now: UInt64, _ then: UInt64, _ dt: TimeInterval) -> Double {
        now >= then ? Double(now - then) / dt : 0
    }

    private static func bsdName(_ bsd: inout proc_bsdinfo) -> String {
        let long = withUnsafePointer(to: &bsd.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 2 * Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        if !long.isEmpty { return long }
        return withUnsafePointer(to: &bsd.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// True while the same process -- not merely the same pid -- is still
    /// there. Checked right before a signal is sent, so a pid recycled between
    /// the click and the kill is not the one that gets it.
    func stillAlive(_ p: ProcSample) -> Bool {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
        let started = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
        return started == p.startedMicros
    }

    // MARK: traces

    private func recordTrace(_ procs: [ProcSample]) {
        var next: [pid_t: [Double]] = [:]
        next.reserveCapacity(procs.count)
        for p in procs {
            var t = trace[p.pid] ?? []
            t.append(p.cpu)
            if t.count > traceMax { t.removeFirst(t.count - traceMax) }
            next[p.pid] = t
        }
        // Whatever is gone is dropped with it: a trace kept for a dead pid
        // would be handed to whatever inherits the number next.
        trace = next
    }

    func traceFor(_ pid: pid_t) -> [Double] { trace[pid] ?? [] }

    // MARK: rules

    struct Flag {
        let proc: ProcSample
        let rule: WatchRule
        /// How long the rule has held for this process.
        let heldFor: TimeInterval
        /// False while `heldFor` is short of the rule's sustain: the conditions
        /// hold, but not yet for long enough to say anything about them.
        let sustained: Bool

        /// How far through the sustain this is, 0 to 1. Always 1 once sustained,
        /// and for a rule with no sustain at all.
        var progress: Double {
            guard !sustained, rule.sustain > 0 else { return 1 }
            return min(max(heldFor / rule.sustain, 0), 1)
        }
    }

    /// What the enabled rules make of a sample: what they flag, and what they
    /// are still counting. `now` is a parameter so the sustain clock can be
    /// tested without waiting for it.
    ///
    /// One entry per process either way. A process whose rule has held long
    /// enough is flagged by the first such rule in the list; one whose rules
    /// are all still counting is reported as holding, by whichever is closest
    /// to firing -- that being the one about to matter.
    struct Verdict {
        var flagged: [Flag] = []
        var holding: [Flag] = []
    }

    /// `excluded` holds app paths that are never flagged, whatever the rules
    /// say. Skipped before the clocks are touched, so an excluded process
    /// accumulates nothing and un-excluding one starts it from zero.
    func evaluate(_ procs: [ProcSample], rules: [WatchRule],
                  excluded: Set<String> = [], now: Date = Date()) -> Verdict {
        var v = Verdict()
        var touched = Set<String>()
        for p in procs {
            if !excluded.isEmpty, !p.appPath.isEmpty, excluded.contains(p.appPath) { continue }
            var flagged: Flag?
            var holding: Flag?
            for r in rules where r.enabled {
                let key = "\(p.pid)/\(p.startedMicros)/\(r.id.uuidString)"
                guard r.holds(for: p) else { since.removeValue(forKey: key); continue }
                touched.insert(key)
                let from = since[key] ?? now
                since[key] = from
                let held = now.timeIntervalSince(from)
                if held >= r.sustain {
                    if flagged == nil {
                        flagged = Flag(proc: p, rule: r, heldFor: held, sustained: true)
                    }
                } else {
                    let f = Flag(proc: p, rule: r, heldFor: held, sustained: false)
                    if holding == nil || f.progress > holding!.progress { holding = f }
                }
            }
            if let f = flagged {
                v.flagged.append(f)
            } else if let h = holding {
                v.holding.append(h)
            }
        }
        // Clocks for processes that have gone, or rules that no longer hold.
        since = since.filter { touched.contains($0.key) }
        v.flagged.sort { $0.proc.cpu > $1.proc.cpu }
        v.holding.sort { $0.progress > $1.progress }
        return v
    }

    /// Forget the sustain clocks for a rule whose conditions changed, so the
    /// new conditions have to hold for the full duration in their own right.
    func reset(rule id: UUID) {
        let suffix = "/" + id.uuidString
        since = since.filter { !$0.key.hasSuffix(suffix) }
    }

    /// Forget every clock. Used when the whole rule set is replaced, as it is
    /// when a profile is picked: the new rules have not held for any time yet.
    func resetAll() { since = [:] }

    // MARK: the machine

    func systemLoad() -> SystemLoad {
        var load = SystemLoad(cpu: nil, ncpu: ProcessInfo.processInfo.activeProcessorCount,
                              gpu: gpuUtilization(), memUsed: 0,
                              memTotal: ProcessInfo.processInfo.physicalMemory)
        if let ticks = Self.hostCPUTicks() {
            if let p = prevHost, ticks.total > p.total {
                load.cpu = Double(ticks.busy - p.busy) / Double(ticks.total - p.total)
            }
            prevHost = ticks
        }
        load.memUsed = Self.hostMemoryUsed()
        return load
    }

    private static func hostCPUTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + sys + nice, user + sys + nice + idle)
    }

    /// What Activity Monitor calls Memory Used: app memory less what is
    /// purgeable, plus wired, plus compressed.
    private static func hostMemoryUsed() -> UInt64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0
        return (UInt64(app) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
    }
}

// MARK: - the live context

/// Which pids are apps meant to have a user interface.
///
/// Separate from the rest of the context because NSWorkspace is a main-thread
/// API, and the rest of the context must not run on the main thread.
func guiAppPIDs() -> Set<pid_t> {
    var gui: Set<pid_t> = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        gui.insert(app.processIdentifier)
    }
    return gui
}

/// What the running apps say about themselves right now, given the GUI apps
/// gathered on the main thread.
///
/// Call this on the sampling queue, never on the main one. The probe waits --
/// by design -- on exactly the apps that are not answering; on the main thread
/// a few of those would freeze this app rather than report them.
///
/// It is off unless asked for: it needs Accessibility, which is the one
/// permission this app can want, so it is never taken silently.
///
/// The window count does not come from CGWindowListCopyWindowInfo, which needs
/// no permission and cannot answer the question. Asked for on-screen windows
/// only, it reports nothing for every app whose windows are on another Space or
/// minimised. Asked for all windows, it keeps reporting windows an app has
/// already closed -- measured here: TextEdit with every document closed still
/// listed the two it used to have, unchanged. Either way it would flag apps
/// that are fine or never flag anything, so the accessibility list, which
/// tracks what an app actually has, is the only source worth using.
func liveContext(guiApps gui: Set<pid_t>, inspectApps: Bool) -> (ProcContext, WatchCapability) {
    var ctx = ProcContext()
    var cap = WatchCapability()
    ctx.guiApps = gui

    guard inspectApps else { return (ctx, cap) }
    guard AXIsProcessTrusted() else {
        cap.reason = "Reaper has not been granted Accessibility"
        return (ctx, cap)
    }
    cap.appsInspected = true
    cap.reason = ""
    // Only GUI apps: a daemon has no accessibility port to answer on, so asking
    // one would report every background process as hung and windowless.
    for pid in gui {
        ctx.probed.insert(pid)
        let r = probeApp(pid)
        if r.responsive {
            if let n = r.windows { ctx.windows[pid] = n }
        } else {
            ctx.unresponsive.insert(pid)
        }
    }
    return (ctx, cap)
}

/// Asks an app for its windows, with a short deadline, and gets two answers.
///
/// A hung app is one whose main thread is not draining its event queue, so it
/// cannot reply and the request times out as kAXErrorCannotComplete. An app
/// that does reply has told you, in the same breath, how many windows it has.
/// The two states are the same question asked of the same port, which is why
/// one call serves both.
///
/// The deadline is the whole mechanism: without one, this blocks for the system
/// default of six seconds against exactly the apps it is meant to detect.
func probeApp(_ pid: pid_t, timeout: Float = 0.25) -> (responsive: Bool, windows: Int?) {
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, timeout)
    var value: CFTypeRef?
    let rc = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value)
    switch rc {
    case .success:
        // Minimised windows and windows on other Spaces are in this list, and
        // should be: the app has something to come back to either way.
        return (true, (value as? [AXUIElement])?.count ?? 0)
    case .cannotComplete:
        return (false, nil)
    default:
        // It answered, with something other than a window list: not hung, but
        // not saying how many windows it has either. An app that refuses the
        // attribute is not one to flag for lacking it.
        return (true, nil)
    }
}

/// System-wide GPU utilisation from the accelerator driver's own statistics.
/// System-wide is all macOS offers without private frameworks -- there is no
/// public per-process GPU figure -- which is why GPU is a headline number in the
/// window and not a rule threshold.
func gpuUtilization() -> Double? {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)
            == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    var best: Double?
    var entry = IOIteratorNext(it)
    while entry != 0 {
        if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                       kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
            // Apple Silicon and Intel integrated GPUs use the first key, AMD the second.
            if let n = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, n.doubleValue)
            }
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(it)
    }
    return best
}

// MARK: - the detail a row cannot hold

/// The command line, for telling apart several processes that share a name --
/// which of six Chrome helpers is the one rendering a page nobody is looking
/// at. The kernel only answers for the user's own processes, which is all that
/// is ever listed, and not for a zombie, which has no arguments left.
func procArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var raw = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &raw, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = Int(raw.withUnsafeBytes { $0.load(as: Int32.self) })
    // Layout: argc, the executable path, NUL padding, then argc strings.
    var i = 4
    while i < size && raw[i] != 0 { i += 1 }
    while i < size && raw[i] == 0 { i += 1 }
    var args: [String] = []
    var start = i
    while i < size && args.count < argc {
        if raw[i] == 0 {
            args.append(String(decoding: raw[start..<i], as: UTF8.self))
            start = i + 1
        }
        i += 1
    }
    return args
}

/// Threads and open file descriptors. Two numbers the detail window shows
/// because they are what distinguishes a process that is stuck from one that is
/// merely busy: a hung app keeps its threads and stops opening anything.
/// nil where the kernel would not answer, which includes every zombie.
func threadCount(_ pid: pid_t) -> Int? {
    var ti = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { return nil }
    return Int(ti.pti_threadnum)
}

func fdCount(_ pid: pid_t) -> Int? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return nil }
    return Int(bytes) / MemoryLayout<proc_fdinfo>.size
}

/// The bundle identifier of the app a pid belongs to, when it is one.
func bundleID(_ pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}
