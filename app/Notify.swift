//
// One notification the first time a process is flagged.
//
// The mark was meant to be the alert, and for a menu bar that is on screen it
// is. But it is not on screen in a full-screen app, and the premise of the
// whole thing is that you should not have to think to look -- which a mark you
// have to look at only half satisfies. So: off by default, one per flag rather
// than one per tick, and nothing for the amber state, which is by definition
// not yet worth interrupting anyone for.
//
// Not linked into the test binary. UNUserNotificationCenter.current() raises
// when the process has no bundle, which is exactly how the tests run.
//

import AppKit
import UserNotifications

enum Notify {
    /// Whether the centre has said yes. nil until it has been asked.
    private(set) static var authorized: Bool?

    /// Asked for only when the switch is turned on, and only once per launch.
    static func request(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { granted, _ in
                DispatchQueue.main.async {
                    authorized = granted
                    done(granted)
                }
            }
    }

    /// Posts one line per newly flagged process.
    ///
    /// Capped: a rule with no sustain, edited to something most processes
    /// match, would otherwise deliver a notification per process in one tick.
    /// The mark already carries the count, so beyond a few the useful message
    /// is "look at the window", not each name in turn.
    static func post(_ events: [FlagEvent]) {
        guard authorized == true, !events.isEmpty else { return }
        let centre = UNUserNotificationCenter.current()
        for e in events.prefix(3) {
            let c = UNMutableNotificationContent()
            c.title = "\(e.name) flagged"
            c.body = e.wasZombie
                ? "\(e.rule): \(e.summary)"
                : "\(e.rule): \(e.summary) \u{2014} now at \(fmtCPU(e.peakCPU))"
            c.sound = nil
            centre.add(UNNotificationRequest(identifier: e.id.uuidString,
                                             content: c, trigger: nil))
        }
        if events.count > 3 {
            let c = UNMutableNotificationContent()
            c.title = "\(events.count) processes flagged"
            c.body = "Open Reaper to see the rest."
            c.sound = nil
            centre.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: c, trigger: nil))
        }
    }
}
