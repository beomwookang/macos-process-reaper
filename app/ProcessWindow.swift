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

private let INNER: CGFloat = 760
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

    private struct Row { let proc: ProcSample; let flag: ProcTracker.Flag? }
    private var procs: [ProcSample] = []
    private var flags: [ProcTracker.Flag] = []
    private var holding: [ProcTracker.Flag] = []
    private var rows: [Row] = []
    private var showAll: Bool
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
    private let mode = NSSegmentedControl(labels: ["Flagged", "All, by CPU"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let context = NSMenu()
    private let note = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    // MARK: - setup

    init(profiles: [Profile], active: UUID, showAll: Bool) {
        self.profiles = profiles
        self.activeID = active
        self.showAll = showAll
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

        // --- rules
        let rulesTitle = label("Rules")
        rulesTitle.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(row([rulesTitle, NSView(),
                                      button("Add Rule", #selector(addRule))]))

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 10
        stack.addArrangedSubview(rulesStack)
        rebuildRules()

        stack.addArrangedSubview(label(
            "Every condition a rule sets has to hold, and keep holding for its \u{201C}for\u{201D} "
            + "time, before a process is flagged. CPU is percent of one core, as in top: 800 is "
            + "eight cores busy. Leave a number empty to leave it out of the rule. Editing a rule "
            + "restarts its clock.",
            size: 11, color: .secondaryLabelColor, wrap: INNER))

        // --- the list
        listTitle.font = .boldSystemFont(ofSize: 13)
        mode.selectedSegment = showAll ? 1 : 0
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        mode.target = self
        mode.action = #selector(modeChanged)
        stack.addArrangedSubview(row([listTitle, NSView(), mode]))

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

            // Line two: the states, indented under the name, and the reason the
            // rule cannot currently see when that is the case.
            var stateViews: [NSView] = [spacer(28), caption("state")]
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
                let warn = label("\u{2014} inactive: \(why)", size: 11, color: .systemOrange)
                warn.toolTip = "This rule is switched on, but cannot see what it needs to, "
                             + "so it is flagging nothing."
                stateViews.append(warn)
            }
            stateViews.append(NSView())
            let states = NSStackView(views: stateViews)
            states.spacing = 10
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
                case "cpu": f.stringValue = r.minCPU.map(fmtNum) ?? ""
                case "mem": f.stringValue = r.minMemoryMB.map(fmtNum) ?? ""
                case "age": f.stringValue = r.minAgeHours.map(fmtNum) ?? ""
                default:    f.stringValue = r.sustain > 0 ? fmtNum(r.sustain / 60) : ""
                }
                return
            }
            switch parts[1] {
            case "cpu": r.minCPU = num
            case "mem": r.minMemoryMB = num
            case "age": r.minAgeHours = num
            case "for": r.sustain = (num ?? 0) * 60
            default: return
            }
        }
        guard r != rs[i] else { return }
        rs[i] = r
        resetNote()
        commitRules(rs)
    }

    // MARK: - table

    private func buildTable() {
        // Fixed widths for the numbers; the name takes whatever is left. The
        // sum has to come in under the table, or the last column is clipped
        // rather than the first one narrowed.
        let cols: [(String, String, CGFloat)] = [
            ("name", "Process", 268), ("pid", "PID", 54), ("cpu", "CPU", 58),
            ("mem", "Memory", 72), ("age", "Running", 74), ("rule", "Rule", 112), ("kill", "", 74),
        ]
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
        guard let col, row < rows.count else { return nil }
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
        guard row >= 0, row < rows.count else { return }
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
                capability: WatchCapability, termSent: [pid_t: Date]) {
        self.procs = procs
        self.flags = verdict.flagged
        self.holding = verdict.holding
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
        if showAll {
            rows = procs.sorted { $0.cpu > $1.cpu }.prefix(120)
                        .map { Row(proc: $0, flag: byPid[$0.pid]) }
            listTitle.stringValue = "All \(procs.count) of your processes, busiest first"
        } else {
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
        }
        table.reloadData()
    }

    @objc private func modeChanged() {
        showAll = mode.selectedSegment == 1
        onShowAllChanged?(showAll)
        rebuildRows()
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
