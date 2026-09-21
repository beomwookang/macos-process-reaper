//
// The process window: the profile, the rules under it, and what they flag.
//
// Three bands. The profile at the top is the choice most people will only make
// once. The rules beneath it are that choice spelled out, editable in place --
// a rule is a name, four numbers and four states, and does not deserve a
// dialog. The table at the bottom is what those rules make of the machine right
// now, each row ending in the button that ends the process.
//
// Everything refreshes on the app's own tick while the window is up.
//

import AppKit

private let INNER: CGFloat = 880
private let PAD: CGFloat = 20
private let TABLE_H: CGFloat = 260

final class ProcessWindow: NSWindowController, NSWindowDelegate, NSMenuDelegate,
                           NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    // MARK: - wiring

    /// The whole profile list, whenever a rule or a profile changes. The app
    /// saves it and restarts the sustain clocks of whatever changed.
    var onProfilesChanged: (([Profile]) -> Void)?
    /// A different profile was picked.
    var onActiveChanged: ((UUID) -> Void)?
    /// Sends the signal. Returns an error message, or nil on success.
    var onKill: ((ProcSample, Int32) -> String?)?
    /// Asks the app to sample now rather than at the next tick.
    var onRefresh: (() -> Void)?
    /// Opens the detail window for one process.
    var onDetail: ((ProcSample) -> Void)?
    /// The table's mode is remembered between launches, so it goes to settings.
    var onShowAllChanged: ((Bool) -> Void)?
    /// The exclusion list changed -- one was removed here, or added from a row.
    var onExclusionsChanged: (([Exclusion]) -> Void)?
    /// Forget the history.
    var onClearHistory: (() -> Void)?
    /// The rule editor was opened or closed; remembered between launches.
    var onRulesOpenChanged: ((Bool) -> Void)?

    private(set) var profiles: [Profile]
    private(set) var activeID: UUID

    /// The rules of the active profile: what the editor edits and the table
    /// explains itself by.
    private var rules: [WatchRule] {
        get { profiles.first { $0.id == activeID }?.rules ?? [] }
        set {
            guard let i = profiles.firstIndex(where: { $0.id == activeID }) else { return }
            profiles[i].rules = newValue
        }
    }

    // MARK: - state

    /// Which list the table is showing. History is a different set of columns
    /// rather than the same ones meaning different things, so the headers can
    /// never describe the wrong thing.
    private enum Mode: Int { case flagged = 0, all = 1, history = 2 }

    private struct Row { let proc: ProcSample; let flag: ProcTracker.Flag? }
    private var procs: [ProcSample] = []
    private var flags: [ProcTracker.Flag] = []
    private var holding: [ProcTracker.Flag] = []
    private var rows: [Row] = []
    private var past: [FlagEvent] = []
    private var exclusions: [Exclusion] = []
    private var mode2: Mode = .flagged
    private var cap = WatchCapability()

    /// When SIGTERM went out, per pid -- the app's record, pushed in with each
    /// update so a kill from the menu shows here too, and set locally as well
    /// so the button changes under the click rather than on the next tick.
    private var termSent: [pid_t: Date] = [:]
    private let grace: TimeInterval = 3

    // MARK: - views

    private let headline = NSTextField(labelWithString: "")
    private let profileBar = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let profileNote = NSTextField(labelWithString: "")
    private let rulesStack = NSStackView()
    private let listTitle = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["Flagged", "All, by CPU", "History"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let clearHistory = NSButton(title: "Clear", target: nil, action: nil)
    private let rulesToggle = NSButton()
    private let rulesNote = NSTextField(labelWithString: "")
    private let addRuleButton = NSButton(title: "Add Rule", target: nil, action: nil)
    private let rulesHelp = NSTextField(labelWithString: "")
    private let exclusionTitle = NSTextField(labelWithString: "")
    private let exclusionStack = NSStackView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let context = NSMenu()
    private let note = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    // MARK: - setup

    private var rulesOpen: Bool

    init(profiles: [Profile], active: UUID, showAll: Bool, exclusions: [Exclusion],
         rulesOpen: Bool) {
        self.profiles = profiles
        self.activeID = active
        self.mode2 = showAll ? .all : .flagged
        self.exclusions = exclusions
        self.rulesOpen = rulesOpen
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: INNER + PAD * 2, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Processes"
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, size: CGFloat = 13, color: NSColor = .labelColor,
                       wrap: CGFloat? = nil) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size)
        t.textColor = color
        if let wrap {
            t.lineBreakMode = .byWordWrapping
            t.maximumNumberOfLines = 0
            t.preferredMaxLayoutWidth = wrap
            t.widthAnchor.constraint(equalToConstant: wrap).isActive = true
        }
        return t
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views)
        r.spacing = spacing
        r.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        return r
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: PAD, bottom: 16, right: PAD)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- the machine as a whole, so the list below has a denominator
        headline.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        headline.textColor = .secondaryLabelColor
        headline.stringValue = "reading\u{2026}"
        headline.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(headline)

        // --- profile: the choice, before the numbers behind it
        let profileTitle = label("Profile")
        profileTitle.font = .boldSystemFont(ofSize: 13)
        profileBar.target = self
        profileBar.action = #selector(profilePicked)
        profileBar.controlSize = .regular
        stack.addArrangedSubview(row([profileTitle, NSView(),
                                      button("Restore Profiles", #selector(restoreProfiles))]))
        profileNote.font = .systemFont(ofSize: 11)
        profileNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([profileBar, profileNote]))
        rebuildProfileBar()

        // --- rules, behind a disclosure. The profile is the decision most
        // people make once; the numbers under it are real but rarely touched,
        // and nine rules at two lines each make a window taller than a laptop
        // screen. So they open when asked for, and stay open if you ask.
        rulesToggle.setButtonType(.onOff)
        rulesToggle.bezelStyle = .disclosure
        rulesToggle.title = ""
        rulesToggle.target = self
        rulesToggle.action = #selector(toggleRulesOpen)
        rulesToggle.state = rulesOpen ? .on : .off
        let rulesTitle = label("Rules")
        rulesTitle.font = .boldSystemFont(ofSize: 13)
        rulesNote.font = .systemFont(ofSize: 11)
        rulesNote.textColor = .secondaryLabelColor
        addRuleButton.target = self
        addRuleButton.action = #selector(addRule)
        addRuleButton.bezelStyle = .rounded
        addRuleButton.controlSize = .small
        addRuleButton.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(row([rulesToggle, rulesTitle, rulesNote, NSView(),
                                      addRuleButton]))

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 10
        stack.addArrangedSubview(rulesStack)
        rebuildRules()

        rulesHelp.font = .systemFont(ofSize: 11)
        rulesHelp.textColor = .secondaryLabelColor
        rulesHelp.lineBreakMode = .byWordWrapping
        rulesHelp.maximumNumberOfLines = 0
        rulesHelp.preferredMaxLayoutWidth = INNER
        rulesHelp.stringValue =
            "Every condition a rule sets has to hold, and keep holding for its \u{201C}for\u{201D} "
            + "time, before a process is flagged. CPU is percent of one core, as in top: 800 is "
            + "eight cores busy. Leave a number empty to leave it out of the rule. Editing a rule "
            + "restarts its clock."
        rulesHelp.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(rulesHelp)
        applyRulesOpen()

        // --- exclusions, shown only when there are any: a heading over an
        // empty list is a feature advertising itself at the cost of everyone
        // who does not use it.
        exclusionTitle.font = .boldSystemFont(ofSize: 13)
        exclusionTitle.stringValue = "Never flagged"
        stack.addArrangedSubview(row([exclusionTitle, NSView()]))
        exclusionStack.orientation = .vertical
        exclusionStack.alignment = .leading
        exclusionStack.spacing = 3
        stack.addArrangedSubview(exclusionStack)
        rebuildExclusions()

        // --- the list
        listTitle.font = .boldSystemFont(ofSize: 13)
        mode.selectedSegment = mode2.rawValue
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        mode.target = self
        mode.action = #selector(modeChanged)
        clearHistory.target = self
        clearHistory.action = #selector(clearHistoryClicked)
        clearHistory.bezelStyle = .rounded
        clearHistory.controlSize = .small
        clearHistory.font = .systemFont(ofSize: 11)
        clearHistory.isHidden = true
        clearHistory.toolTip = "Forget every entry below."
        stack.addArrangedSubview(row([listTitle, NSView(), clearHistory, mode]))

        buildTable()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        // Low priority: this is the one view that gives when the window is
        // resized, or when the rules above it grow.
        let h = scroll.heightAnchor.constraint(equalToConstant: TABLE_H)
        h.priority = .defaultLow
        h.isActive = true
        stack.addArrangedSubview(scroll)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = INNER
        note.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(note)
        resetNote()

        let close = NSButton(title: "Close", target: self, action: #selector(close_))
        stack.addArrangedSubview(row([NSView(), close]))

        for v in stack.arrangedSubviews where v !== scroll {
            v.setContentHuggingPriority(.required, for: .vertical)
        }
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        // Otherwise the first rule's name opens selected, as if a rename were
        // the reason the window was opened.
        window?.initialFirstResponder = table
        resize(grow: false)
        window?.minSize = NSSize(width: INNER + PAD * 2, height: 420)
        window?.maxSize = NSSize(width: INNER + PAD * 2, height: 4000)
    }

    /// Only the height follows from the content; the width is a decision.
    /// `grow` keeps a window the user has made taller.
    private func resize(grow: Bool) {
        guard let w = window, let cv = w.contentView else { return }
        cv.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize.height
        let h = grow ? max(cv.frame.height, fit) : fit
        w.setContentSize(NSSize(width: INNER + PAD * 2, height: h))
    }

    // MARK: - profiles

    private func rebuildProfileBar() {
        profileBar.segmentCount = profiles.count
        for (i, p) in profiles.enumerated() {
            profileBar.setLabel(p.name, forSegment: i)
            profileBar.setWidth(0, forSegment: i)
            profileBar.setToolTip(p.detail, forSegment: i)
        }
        if let i = profiles.firstIndex(where: { $0.id == activeID }) {
            profileBar.selectedSegment = i
            profileNote.stringValue = profiles[i].detail
        }
    }

    @objc private func profilePicked() {
        let i = profileBar.selectedSegment
        guard i >= 0, i < profiles.count, profiles[i].id != activeID else { return }
        activeID = profiles[i].id
        profileNote.stringValue = profiles[i].detail
        rebuildRules()
        resize(grow: true)
        onActiveChanged?(activeID)
        onRefresh?()
        say("Switched to \(profiles[i].name). Its rules start counting from now.")
    }

    /// Puts each shipped profile back as shipped -- replacing an edited one,
    /// adding a deleted one -- and leaves profiles of the user's own alone.
    @objc private func restoreProfiles() {
        profiles = restoringProfiles(profiles)
        if !profiles.contains(where: { $0.id == activeID }) { activeID = defaultProfileID }
        rebuildProfileBar()
        rebuildRules()
        resize(grow: true)
        onProfilesChanged?(profiles)
        onActiveChanged?(activeID)
        onRefresh?()
        say("Profiles restored.")
    }

    /// Profiles changed elsewhere -- the menu. A no-op when nothing differs,
    /// which is the case when the change came from this window and is only
    /// being echoed back.
    func setProfiles(_ new: [Profile], active: UUID) {
        guard new != profiles || active != activeID else { return }
        profiles = new
        activeID = active
        rebuildProfileBar()
        rebuildRules()
        resize(grow: true)
    }

    // MARK: - rules editor

    /// A checkbox that remembers which rule and which state it stands for.
    /// Encoding both into `tag` worked until a fifth state was imagined.
    private final class StateBox: NSButton {
        var ruleIndex = 0
        /// Not `state`: NSButton already has one, and it means the checkbox.
        var watchState: WatchState = .zombie
    }

    /// Not `cap`: that is the capability, and a caption helper of the same name
    /// made `self.cap` and `cap(...)` two unrelated things one letter apart.
    private func caption(_ s: String) -> NSTextField {
        label(s, size: 11, color: .secondaryLabelColor)
    }

    private func field(_ value: String, width: CGFloat, id: String, align: NSTextAlignment) -> NSTextField {
        let f = NSTextField(string: value)
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.alignment = align
        f.controlSize = .small
        f.identifier = NSUserInterfaceItemIdentifier(id)
        f.delegate = self
        f.placeholderString = "\u{2013}"
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    private func numField(_ value: Double?, width: CGFloat, id: String) -> NSTextField {
        field(value.map(fmtNum) ?? "", width: width, id: id, align: .right)
    }

    private func rebuildRules() {
        for v in rulesStack.arrangedSubviews {
            rulesStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let rules = self.rules
        for (i, r) in rules.enumerated() {
            let on = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRule(_:)))
            on.state = r.enabled ? .on : .off
            on.tag = i
            on.toolTip = "Enabled"

            let remove = NSButton(title: "\u{2212}", target: self, action: #selector(removeRule(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.tag = i
            remove.toolTip = "Remove this rule"

            // Line one: the name and the numbers.
            let numbers = NSStackView(views: [
                on, field(r.name, width: 130, id: "\(i):name", align: .left),
                caption("CPU \u{2265}"), numField(r.minCPU, width: 50, id: "\(i):cpu"), caption("%"),
                caption("mem \u{2265}"), numField(r.minMemoryMB, width: 58, id: "\(i):mem"), caption("MB"),
                caption("age \u{2265}"), numField(r.minAgeHours, width: 44, id: "\(i):age"), caption("h"),
                caption("for"), numField(r.sustain > 0 ? r.sustain / 60 : nil, width: 44, id: "\(i):for"),
                caption("min"),
                NSView(), remove,
            ])
            numbers.spacing = 4
            // A little air between the groups, so the row reads as four
            // conditions rather than one run of boxes.
            for k in [1, 4, 7, 10] where k < numbers.arrangedSubviews.count {
                numbers.setCustomSpacing(12, after: numbers.arrangedSubviews[k])
            }
            numbers.widthAnchor.constraint(equalToConstant: INNER).isActive = true

            // Line two: the two rates, then the states, indented under the
            // name, and a short marker when the rule cannot currently see. The
            // full reason is in that marker's tooltip -- spelled out inline it
            // ran the row past the width of the window.
            var stateViews: [NSView] = [
                spacer(28),
                caption("write \u{2265}"), numField(r.minWriteKBs, width: 58, id: "\(i):write"),
                caption("KB/s"),
                caption("wakeups \u{2265}"), numField(r.minWakeups, width: 44, id: "\(i):wake"),
                caption("/s"),
                caption("state"),
            ]
            for s in WatchState.allCases {
                let box = StateBox(checkboxWithTitle: s.label, target: self,
                                   action: #selector(toggleState(_:)))
                box.ruleIndex = i
                box.watchState = s
                box.state = r.states.contains(s) ? .on : .off
                box.font = .systemFont(ofSize: 11)
                box.toolTip = s.explanation
                stateViews.append(box)
            }
            if let why = r.inactiveReason(self.cap) {
                let warn = label("\u{2014} inactive", size: 11, color: .systemOrange)
                warn.toolTip = "This rule is switched on but cannot see what it needs to, so it "
                             + "is flagging nothing: \(why)."
                stateViews.append(warn)
            }
            stateViews.append(NSView())
            let states = NSStackView(views: stateViews)
            states.spacing = 6
            for k in [0, 3, 6] where k < states.arrangedSubviews.count {
                states.setCustomSpacing(14, after: states.arrangedSubviews[k])
            }
            states.widthAnchor.constraint(equalToConstant: INNER).isActive = true

            let group = NSStackView(views: [numbers, states])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            rulesStack.addArrangedSubview(group)
        }
        if rules.isEmpty {
            rulesStack.addArrangedSubview(label("No rules in this profile. Add one, or restore the profiles.",
                                                size: 11, color: .secondaryLabelColor))
        }
        applyRulesOpen()
    }

    /// One line per excluded app, with the button that puts it back. Hidden
    /// entirely, heading included, when there are none.
    private func rebuildExclusions() {
        for v in exclusionStack.arrangedSubviews {
            exclusionStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        exclusionTitle.isHidden = exclusions.isEmpty
        exclusionStack.isHidden = exclusions.isEmpty
        guard !exclusions.isEmpty else { return }
        for (i, x) in exclusions.enumerated() {
            let put = NSButton(title: "\u{2212}", target: self, action: #selector(removeExclusion(_:)))
            put.bezelStyle = .rounded
            put.controlSize = .small
            put.tag = i
            put.toolTip = "Watch \(x.name) again"
            let name = label(x.name, size: 12)
            name.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let where_ = label((x.appPath as NSString).abbreviatingWithTildeInPath,
                               size: 10, color: .secondaryLabelColor)
            where_.lineBreakMode = .byTruncatingMiddle
            let line = NSStackView(views: [put, name, where_, NSView()])
            line.spacing = 8
            line.widthAnchor.constraint(equalToConstant: INNER).isActive = true
            exclusionStack.addArrangedSubview(line)
        }
    }

    @objc private func removeExclusion(_ sender: NSButton) {
        guard sender.tag < exclusions.count else { return }
        let gone = exclusions.remove(at: sender.tag)
        rebuildExclusions()
        resize(grow: true)
        onExclusionsChanged?(exclusions)
        onRefresh?()
        say("Watching \(gone.name) again. Its rules start counting from now.")
    }

    /// Exclusions changed elsewhere -- a row's context menu, or another window.
    func setExclusions(_ new: [Exclusion]) {
        guard new != exclusions else { return }
        exclusions = new
        rebuildExclusions()
        resize(grow: true)
    }

    /// Shows or hides the editor, and says what is hidden when it is closed --
    /// a bare disclosure triangle over nothing tells you only that something
    /// is missing.
    private func applyRulesOpen() {
        rulesStack.isHidden = !rulesOpen
        rulesHelp.isHidden = !rulesOpen
        addRuleButton.isHidden = !rulesOpen
        let rules = self.rules
        let on = rules.filter { $0.enabled }.count
        let inactive = rules.filter { $0.inactiveReason(cap) != nil }.count
        var note = rulesOpen ? "" : "\(on) of \(rules.count) switched on"
        if !rulesOpen && inactive > 0 { note += ", \(inactive) inactive" }
        rulesNote.stringValue = note
        rulesNote.textColor = inactive > 0 && !rulesOpen ? .systemOrange : .secondaryLabelColor
    }

    @objc private func toggleRulesOpen() {
        rulesOpen = rulesToggle.state == .on
        applyRulesOpen()
        resize(grow: false)
        onRulesOpenChanged?(rulesOpen)
    }

    private func spacer(_ w: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    /// The one path every rule change takes. The profile list goes out whole,
    /// so the app can work out which clocks to restart.
    private func commitRules(_ new: [WatchRule]) {
        rules = new
        onProfilesChanged?(profiles)
        onRefresh?()
    }

    @objc private func toggleRule(_ sender: NSButton) {
        var r = rules
        guard sender.tag < r.count else { return }
        r[sender.tag].enabled = (sender.state == .on)
        commitRules(r)
        rebuildRules()
        resize(grow: true)
    }

    @objc private func toggleState(_ sender: NSButton) {
        guard let box = sender as? StateBox else { return }
        var r = rules
        guard box.ruleIndex < r.count else { return }
        if box.state == .on {
            r[box.ruleIndex].states.insert(box.watchState)
        } else {
            r[box.ruleIndex].states.remove(box.watchState)
        }
        commitRules(r)
        // Rebuilt because adding a state can make the rule inactive, and the
        // reason belongs on the line the person just clicked.
        rebuildRules()
        resize(grow: true)
    }

    @objc private func removeRule(_ sender: NSButton) {
        var r = rules
        guard sender.tag < r.count else { return }
        r.remove(at: sender.tag)
        commitRules(r)
        rebuildRules()
        resize(grow: true)
    }

    @objc private func addRule() {
        if !rulesOpen {
            rulesOpen = true
            rulesToggle.state = .on
            applyRulesOpen()
            onRulesOpenChanged?(true)
        }
        commitRules(rules + [WatchRule(name: "New rule", minCPU: 200, sustain: 60)])
        rebuildRules()
        resize(grow: true)
        // Straight into the name, since "New rule" is not one.
        if let group = rulesStack.arrangedSubviews.last as? NSStackView,
           let line = group.arrangedSubviews.first as? NSStackView,
           line.arrangedSubviews.count > 1 {
            window?.makeFirstResponder(line.arrangedSubviews[1])
        }
    }

    /// One handler for every field. The identifier says which rule and which
    /// number; an entry that is not a number is put back to what it was.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField, let id = f.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        var rs = rules
        guard parts.count == 2, let i = Int(parts[0]), i < rs.count else { return }
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces)
        var r = rs[i]

        if parts[1] == "name" {
            r.name = raw.isEmpty ? "Rule" : raw
            f.stringValue = r.name
        } else {
            let num = raw.isEmpty ? nil : Double(raw)
            if !raw.isEmpty && (num == nil || num! < 0) {
                fail("\u{201C}\(raw)\u{201D} is not a number.")
                switch parts[1] {
                case "cpu":   f.stringValue = r.minCPU.map(fmtNum) ?? ""
                case "mem":   f.stringValue = r.minMemoryMB.map(fmtNum) ?? ""
                case "age":   f.stringValue = r.minAgeHours.map(fmtNum) ?? ""
                case "write": f.stringValue = r.minWriteKBs.map(fmtNum) ?? ""
                case "wake":  f.stringValue = r.minWakeups.map(fmtNum) ?? ""
                default:      f.stringValue = r.sustain > 0 ? fmtNum(r.sustain / 60) : ""
                }
                return
            }
            switch parts[1] {
            case "cpu":   r.minCPU = num
            case "mem":   r.minMemoryMB = num
            case "age":   r.minAgeHours = num
            case "write": r.minWriteKBs = num
            case "wake":  r.minWakeups = num
            case "for":   r.sustain = (num ?? 0) * 60
            default: return
            }
        }
        guard r != rs[i] else { return }
        rs[i] = r
        resetNote()
        commitRules(rs)
    }

    // MARK: - table

    /// Fixed widths for the numbers; the name takes whatever is left. The sum
    /// has to come in under the table, or the last column is clipped rather
    /// than the first one narrowed.
    private static let liveColumns: [(String, String, CGFloat)] = [
        ("name", "Process", 300), ("pid", "PID", 54), ("cpu", "CPU", 58),
        ("mem", "Memory", 72), ("write", "Write", 74), ("age", "Running", 74),
        ("rule", "Rule", 112), ("kill", "", 74),
    ]

    /// A different set, not the same one relabelled: an entry in the history
    /// has a beginning, an end and a worst reading, and none of those is a
    /// current figure.
    /// These have to sum to less than the table, or the last column is clipped
    /// rather than the first one narrowed -- which is how Outcome first came
    /// out reading "Outcor".
    private static let historyColumns: [(String, String, CGFloat)] = [
        ("name", "Process", 254), ("rule", "Flagged by", 116), ("began", "Began", 108),
        ("held", "Lasted", 76), ("peakcpu", "Peak CPU", 76), ("peakmem", "Peak memory", 92),
        ("outcome", "Outcome", 100),
    ]

    /// The widths alone, for the check that they fit.
    static var liveColumnWidths: [CGFloat] { liveColumns.map { $0.2 } }
    static var historyColumnWidths: [CGFloat] { historyColumns.map { $0.2 } }
    static var tableWidth: CGFloat { INNER }

    private func installColumns(_ cols: [(String, String, CGFloat)]) {
        for c in table.tableColumns { table.removeTableColumn(c) }
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            if id == "name" {
                c.minWidth = 180
                c.resizingMask = .autoresizingMask
            } else {
                c.minWidth = w
                c.maxWidth = w
                c.resizingMask = []
            }
            table.addTableColumn(c)
        }
    }

    private func buildTable() {
        installColumns(Self.liveColumns)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 4, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        context.delegate = self
        table.menu = context
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode2 == .history ? past.count : rows.count
    }

    private final class NameCell: NSTableCellView {
        let title = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingMiddle
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            for t in [title, detail] {
                t.translatesAutoresizingMaskIntoConstraints = false
                addSubview(t)
                t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
                t.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3).isActive = true
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3).isActive = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private final class KillCell: NSTableCellView {
        let button = NSButton(title: "Kill", target: nil, action: nil)
        override init(frame: NSRect) {
            super.init(frame: frame)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            button.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            button.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            button.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private func textCell(_ tv: NSTableView, _ col: NSTableColumn, mono: Bool,
                          align: NSTextAlignment) -> NSTableCellView {
        if let v = tv.makeView(withIdentifier: col.identifier, owner: nil) as? NSTableCellView { return v }
        let v = NSTableCellView()
        v.identifier = col.identifier
        let t = NSTextField(labelWithString: "")
        t.font = mono ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                      : .systemFont(ofSize: 12)
        t.alignment = align
        t.lineBreakMode = .byTruncatingTail
        t.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(t)
        v.textField = t
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func parent(of p: ProcSample) -> ProcSample? {
        // launchd is everyone's parent eventually and never the answer.
        guard p.ppid > 1 else { return nil }
        return procs.first { $0.pid == p.ppid }
    }

    /// The app bundle a helper belongs to, or the directory it runs from.
    private func shortPath(_ p: ProcSample) -> String {
        guard !p.path.isEmpty else { return "" }
        if let r = p.path.range(of: ".app/") {
            let bundle = String(p.path[..<r.lowerBound]) + ".app"
            return (bundle as NSString).abbreviatingWithTildeInPath
        }
        return ((p.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    /// The states a process is actually in, for the row's second line. Only the
    /// ones that are true: a list of four with three "no"s in it is noise.
    private func stateWords(_ p: ProcSample) -> [String] {
        var out: [String] = []
        if p.isZombie { out.append("zombie") }
        if p.isOrphan { out.append("orphan") }
        if p.isWindowless == true { out.append("no window") }
        if p.responsive == false { out.append("not responding") }
        return out
    }

    private func tooltip(_ r: Row) -> String {
        var lines: [String] = [r.proc.path.isEmpty ? r.proc.name : r.proc.path]
        let args = procArgs(r.proc.pid)
        if args.count > 1 {
            var cmd = args.dropFirst().joined(separator: " ")
            if cmd.count > 700 { cmd = String(cmd.prefix(700)) + "\u{2026}" }
            lines.append(cmd)
        }
        if let pp = parent(of: r.proc) { lines.append("child of \(pp.name) (\(pp.pid))") }
        let words = stateWords(r.proc)
        if !words.isEmpty { lines.append(words.joined(separator: ", ")) }
        if let f = r.flag {
            lines.append("\(f.rule.name): \(f.rule.summary) \u{2014} holding for \(fmtAge(f.heldFor))")
        }
        lines.append("Double-click for everything else about it.")
        return lines.joined(separator: "\n")
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let col else { return nil }
        if mode2 == .history {
            guard row < past.count else { return nil }
            return historyCell(tv, col, past[row])
        }
        guard row < rows.count else { return nil }
        let r = rows[row], p = r.proc
        switch col.identifier.rawValue {
        case "name":
            let c = (tv.makeView(withIdentifier: col.identifier, owner: nil) as? NameCell)
                ?? { let n = NameCell(); n.identifier = col.identifier; return n }()
            c.title.stringValue = p.name
            // The states first when there are any -- they are the reason the row
            // is here -- then the parent, then the path, which is the part that
            // can afford to be cut.
            var bits: [String] = stateWords(p)
            if let pp = parent(of: p) { bits.append("child of \(pp.name) (\(pp.pid))") }
            let sp = shortPath(p)
            if !sp.isEmpty { bits.append(sp) }
            c.detail.stringValue = bits.joined(separator: "  \u{00B7}  ")
            c.detail.textColor = p.isZombie ? .systemRed : .secondaryLabelColor
            c.toolTip = tooltip(r)
            return c
        case "pid":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = "\(p.pid)"
            c.textField?.textColor = .secondaryLabelColor
            return c
        case "cpu":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = p.isZombie ? "\u{2013}" : fmtCPU(p.cpu)
            c.textField?.textColor = p.isZombie ? .tertiaryLabelColor : loadColor(p.cpu)
            return c
        case "mem":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = p.isZombie ? "\u{2013}" : fmtBytes(p.memory)
            c.textField?.textColor = p.isZombie ? .tertiaryLabelColor : .labelColor
            return c
        case "write":
            let c = textCell(tv, col, mono: true, align: .right)
            // Quiet at nothing: almost every process writes nothing most of the
            // time, and a column of zeroes would bury the one that does not.
            c.textField?.stringValue = p.isZombie ? "\u{2013}"
                : (p.writeRate < 512 ? "\u{2013}" : fmtRate(p.writeRate))
            c.textField?.textColor = p.writeRate > 1_048_576 ? .systemOrange : .secondaryLabelColor
            c.toolTip = p.isZombie ? nil
                : "read \(fmtRate(p.readRate))   \u{00B7}   wake-ups \(fmtWakeups(p.wakeupRate))"
            return c
        case "age":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = fmtAge(p.age)
            c.textField?.textColor = .labelColor
            return c
        case "rule":
            let c = textCell(tv, col, mono: false, align: .left)
            if let f = r.flag {
                c.textField?.stringValue = f.sustained
                    ? f.rule.name
                    : "\(f.rule.name) \(Int(f.progress * 100))%"
                c.textField?.textColor = f.sustained ? .secondaryLabelColor : .systemOrange
                c.toolTip = f.sustained
                    ? "\(f.rule.summary) \u{2014} holding for \(fmtAge(f.heldFor))"
                    : "\(f.rule.summary) \u{2014} held for \(fmtAge(f.heldFor)) of \(fmtAge(f.rule.sustain))"
            } else {
                c.textField?.stringValue = ""
                c.textField?.textColor = .secondaryLabelColor
                c.toolTip = nil
            }
            return c
        case "kill":
            let c = (tv.makeView(withIdentifier: col.identifier, owner: nil) as? KillCell)
                ?? { let k = KillCell(); k.identifier = col.identifier; return k }()
            c.button.target = self
            c.button.action = #selector(killClicked(_:))
            let target = killTarget(p, parent: parent(of: p))
            styleKillButton(c.button, for: p, target: target,
                            termSentAt: termSent[target?.pid ?? p.pid], grace: grace)
            return c
        default:
            return nil
        }
    }

    /// One past flag. Nothing here is a current reading, so nothing here gets
    /// a live colour except the peak, which is a reading of a moment that has
    /// gone and is coloured as it was.
    private func historyCell(_ tv: NSTableView, _ col: NSTableColumn,
                             _ e: FlagEvent) -> NSView? {
        switch col.identifier.rawValue {
        case "name":
            let c = (tv.makeView(withIdentifier: col.identifier, owner: nil) as? NameCell)
                ?? { let n = NameCell(); n.identifier = col.identifier; return n }()
            c.title.stringValue = e.name
            var bits: [String] = ["pid \(e.pid)"]
            if e.wasZombie { bits.append("zombie") }
            if !e.appPath.isEmpty {
                bits.append((e.appPath as NSString).abbreviatingWithTildeInPath)
            }
            c.detail.stringValue = bits.joined(separator: "  \u{00B7}  ")
            c.detail.textColor = e.wasZombie ? .systemRed : .secondaryLabelColor
            c.toolTip = "\(e.rule): \(e.summary)\n"
                + "began \(fmtWhen(e.began.timeIntervalSince1970))\n"
                + (e.ended == nil ? "still flagged"
                   : "ended \(fmtWhen(e.ended!.timeIntervalSince1970))")
            return c
        case "rule":
            let c = textCell(tv, col, mono: false, align: .left)
            c.textField?.stringValue = e.rule
            c.textField?.textColor = .secondaryLabelColor
            c.toolTip = e.summary
            return c
        case "began":
            let c = textCell(tv, col, mono: true, align: .left)
            c.textField?.stringValue = fmtAgo(e.began)
            c.textField?.textColor = .labelColor
            c.toolTip = fmtWhen(e.began.timeIntervalSince1970)
            return c
        case "held":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = fmtAge(e.duration())
            c.textField?.textColor = .labelColor
            return c
        case "peakcpu":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = e.wasZombie ? "\u{2013}" : fmtCPU(e.peakCPU)
            c.textField?.textColor = e.wasZombie ? .tertiaryLabelColor : loadColor(e.peakCPU)
            return c
        case "peakmem":
            let c = textCell(tv, col, mono: true, align: .right)
            c.textField?.stringValue = e.wasZombie ? "\u{2013}" : fmtBytes(e.peakMemory)
            c.textField?.textColor = e.wasZombie ? .tertiaryLabelColor : .labelColor
            c.toolTip = e.peakWriteRate < 512 ? nil
                : "peak write \(fmtRate(e.peakWriteRate))"
            return c
        case "outcome":
            let c = textCell(tv, col, mono: false, align: .left)
            // Three different things, and the difference is the whole value of
            // keeping the entry: it stopped, or you stopped it, or it has not.
            if e.ended == nil {
                c.textField?.stringValue = "still"
                c.textField?.textColor = .systemRed
                c.toolTip = "Still flagged right now."
            } else if e.signalled {
                c.textField?.stringValue = "ended by you"
                c.textField?.textColor = .secondaryLabelColor
                c.toolTip = "A signal went out from Reaper while this was listed."
            } else {
                c.textField?.stringValue = "went away"
                c.textField?.textColor = .secondaryLabelColor
                c.toolTip = "It stopped matching the rule, or it exited, on its own."
            }
            return c
        default:
            return nil
        }
    }

    // MARK: - killing

    private func send(_ p: ProcSample, _ sig: Int32) {
        if let err = onKill?(p, sig) { fail(err); return }
        if termSent[p.pid] == nil { termSent[p.pid] = Date() }
        say("Sent \(sig == SIGKILL ? "SIGKILL" : "SIGTERM") to \(p.name) (\(p.pid)).")
        table.reloadData()
        // A fresh sample shortly, so the row goes rather than lingering until
        // the next tick; and one after the grace period, so a survivor's
        // button turns to Force without waiting to be noticed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.onRefresh?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 0.3) { [weak self] in self?.onRefresh?() }
    }

    @objc private func killClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < rows.count else { return }
        let p = rows[row].proc
        guard let target = killTarget(p, parent: parent(of: p)) else { return }
        let force = termSent[target.pid].map { Date().timeIntervalSince($0) > grace } ?? false
        send(target, force ? SIGKILL : SIGTERM)
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onDetail?(rows[row].proc)
    }

    /// The right-click menu: the two signals, the parent -- which is the one
    /// that matters for a helper process -- and the way into the detail. Kill a
    /// browser's GPU helper and the browser starts another; kill the browser
    /// and both are gone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        // The history's rows are things that already happened; there is nothing
        // to signal and nothing to look at live.
        guard mode2 != .history, row >= 0, row < rows.count else { return }
        let p = rows[row].proc
        func item(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.tag = row
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        menu.autoenablesItems = false
        let pp = parent(of: p)
        let signalable = killability(of: p) == .yes
        item("Details\u{2026}", #selector(ctxDetail(_:)))
        menu.addItem(.separator())
        item("Kill \(p.name)  (SIGTERM)", #selector(ctxTerm(_:)), enabled: signalable)
        item("Force Kill \(p.name)  (SIGKILL)", #selector(ctxKill(_:)), enabled: signalable)
        if let pp {
            menu.addItem(.separator())
            item("Kill Parent: \(pp.name) (\(pp.pid))  (SIGTERM)", #selector(ctxParent(_:)),
                 enabled: killability(of: pp) == .yes)
        }
        menu.addItem(.separator())
        // The escape hatch. Without it the only way to stop a rule flagging a
        // legitimate long job is to switch the rule off, which loses the
        // detection instead of narrowing it.
        let already = exclusions.contains { $0.appPath == p.appPath }
        item(already ? "Already never flagged: \(p.appName)" : "Never Flag \(p.appName)",
             #selector(ctxExclude(_:)), enabled: !already && !p.appPath.isEmpty)

        menu.addItem(.separator())
        item("Copy Command Line", #selector(ctxCopy(_:)))
        item("Show in Finder", #selector(ctxReveal(_:)), enabled: !p.path.isEmpty)
    }

    private func clicked(_ sender: NSMenuItem) -> ProcSample? {
        sender.tag < rows.count ? rows[sender.tag].proc : nil
    }
    @objc private func ctxDetail(_ s: NSMenuItem) { if let p = clicked(s) { onDetail?(p) } }
    @objc private func ctxTerm(_ s: NSMenuItem) { if let p = clicked(s) { send(p, SIGTERM) } }
    @objc private func ctxKill(_ s: NSMenuItem) { if let p = clicked(s) { send(p, SIGKILL) } }
    @objc private func ctxParent(_ s: NSMenuItem) {
        if let p = clicked(s), let pp = parent(of: p) { send(pp, SIGTERM) }
    }
    @objc private func ctxExclude(_ s: NSMenuItem) {
        guard let p = clicked(s), let x = Exclusion(p),
              !exclusions.contains(where: { $0.appPath == x.appPath }) else { return }
        exclusions.append(x)
        rebuildExclusions()
        resize(grow: true)
        onExclusionsChanged?(exclusions)
        onRefresh?()
        say("\(x.name) will not be flagged again. Remove it from Never flagged above to undo.")
    }

    @objc private func ctxCopy(_ s: NSMenuItem) {
        guard let p = clicked(s) else { return }
        let args = procArgs(p.pid)
        let text = args.isEmpty ? p.path : args.joined(separator: " ")
        guard !text.isEmpty else { fail("\(p.name) (\(p.pid)) has no command line left to copy."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say("Copied the command line of \(p.name) (\(p.pid)).")
    }
    @objc private func ctxReveal(_ s: NSMenuItem) {
        guard let p = clicked(s), !p.path.isEmpty else { return }
        // The bundle for an app, so Finder shows the icon and not a Contents folder.
        var target = p.path
        if let r = p.path.range(of: ".app/") { target = String(p.path[..<r.lowerBound]) + ".app" }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    // MARK: - live data

    /// Pushed by the app on its tick. The rows are rebuilt from scratch: they
    /// are cheap, and diffing them would be more code than the table.
    func update(load: SystemLoad?, procs: [ProcSample], verdict: ProcTracker.Verdict,
                capability: WatchCapability, history: [FlagEvent], termSent: [pid_t: Date]) {
        self.procs = procs
        self.flags = verdict.flagged
        self.holding = verdict.holding
        self.past = history
        self.termSent = termSent
        if let load { headline.stringValue = Self.headlineText(load) }
        // A capability that has changed puts a reason on -- or takes one off --
        // every rule that depends on it, so the editor is rebuilt for it.
        if capability.appsInspected != cap.appsInspected || capability.reason != cap.reason {
            cap = capability
            rebuildRules()
            resize(grow: true)
        }
        rebuildRows()
    }

    static func headlineText(_ l: SystemLoad) -> String {
        var bits: [String] = []
        bits.append(l.cpu.map { String(format: "CPU %.0f%% of %d cores", $0 * 100, l.ncpu) }
                    ?? "CPU \u{2013} of \(l.ncpu) cores")
        bits.append(l.gpu.map { String(format: "GPU %.0f%%", $0) } ?? "GPU \u{2013}")
        bits.append("Memory \(fmtBytes(l.memUsed)) of \(fmtBytes(l.memTotal))")
        return bits.joined(separator: "     ")
    }

    private func rebuildRows() {
        var byPid: [pid_t: ProcTracker.Flag] = [:]
        for f in holding + flags { byPid[f.proc.pid] = f }
        switch mode2 {
        case .all:
            rows = procs.sorted { $0.cpu > $1.cpu }.prefix(120)
                        .map { Row(proc: $0, flag: byPid[$0.pid]) }
            listTitle.stringValue = "All \(procs.count) of your processes, busiest first"
        case .flagged:
            // What is flagged, then what is counting towards being flagged: the
            // second list is why the mark is amber, so hiding it would leave the
            // window unable to explain the icon.
            rows = flags.map { Row(proc: $0.proc, flag: $0) }
                  + holding.map { Row(proc: $0.proc, flag: $0) }
            if flags.isEmpty && holding.isEmpty {
                listTitle.stringValue = "Flagged: nothing"
            } else if holding.isEmpty {
                listTitle.stringValue = "Flagged: \(flags.count)"
            } else {
                listTitle.stringValue = "Flagged: \(flags.count) \u{00B7} counting: \(holding.count)"
            }
        case .history:
            listTitle.stringValue = past.isEmpty
                ? "History: nothing flagged yet"
                : "History: \(past.count) flag\(past.count == 1 ? "" : "s"), newest first"
        }
        table.reloadData()
    }

    @objc private func modeChanged() {
        let want = Mode(rawValue: mode.selectedSegment) ?? .flagged
        guard want != mode2 else { return }
        let wasHistory = mode2 == .history
        mode2 = want
        // The columns are the mode's, so they are swapped rather than
        // relabelled -- a header that describes the wrong thing is worse than a
        // moment's flicker.
        if wasHistory != (mode2 == .history) {
            installColumns(mode2 == .history ? Self.historyColumns : Self.liveColumns)
        }
        clearHistory.isHidden = mode2 != .history
        // Only the live modes are worth remembering: reopening the window on
        // the history would hide what is wrong now, which is its first job.
        if mode2 != .history { onShowAllChanged?(mode2 == .all) }
        rebuildRows()
    }

    @objc private func clearHistoryClicked() {
        guard !past.isEmpty else { return }
        let n = past.count
        past = []
        onClearHistory?()
        rebuildRows()
        say("Forgot \(n) entr\(n == 1 ? "y" : "ies").")
    }

    // MARK: - notes

    private func resetNote() {
        note.textColor = .secondaryLabelColor
        note.stringValue = "Only your own processes are listed: macOS refuses the numbers for "
            + "anyone else\u{2019}s, and refuses the kill too. GPU is system-wide; there is no "
            + "per-process figure. Nothing is ever killed for you."
    }
    private func say(_ s: String) {
        note.textColor = .systemGreen
        note.stringValue = s
    }
    private func fail(_ s: String) {
        note.textColor = .systemRed
        note.stringValue = s
    }

    @objc private func close_() { window?.close() }
}
