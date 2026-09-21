//
// One process, in full: what it is, where it came from, what it is doing, and
// why a rule picked it out.
//
// The table row has room for a name and five numbers. This window is for the
// question the row provokes -- "which of the six helpers is this, and what is it
// for" -- so the things that identify a process rather than measure it are the
// ones given space: the full command line, the chain of parents, the bundle it
// belongs to, and the states it is in spelled out in words.
//

import AppKit

private let INNER: CGFloat = 620
private let PAD: CGFloat = 20

// MARK: - the trace

/// A process's recent CPU, oldest on the left.
///
/// Auto-ranged, but never to less than one core: zooming into a percent of
/// noise makes an idle process look like it is thrashing, which is the opposite
/// of what this window is for.
final class SparkView: NSView {
    private var values: [Double] = []
    private var interval: TimeInterval = 5

    override var intrinsicContentSize: NSSize { NSSize(width: INNER, height: 54) }

    func update(_ v: [Double], interval: TimeInterval) {
        values = v
        self.interval = interval
        needsDisplay = true
    }

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
    }

    override func draw(_ dirty: NSRect) {
        let gutter: CGFloat = 38
        let plot = NSRect(x: 0, y: 14, width: bounds.width - gutter, height: bounds.height - 18)

        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 3, yRadius: 3).fill()

        guard values.count >= 2 else {
            text("collecting\u{2026}", NSPoint(x: 6, y: plot.midY - 5), size: 10,
                 color: .tertiaryLabelColor)
            return
        }

        let hi = max(values.max() ?? 0, 100)
        let peak = values.max() ?? 0
        let path = NSBezierPath()
        for (i, v) in values.enumerated() {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = plot.minY + plot.height * CGFloat(min(max(v / hi, 0), 1))
            i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        let ink = loadColor(peak)
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
        fill.close()
        ink.withAlphaComponent(0.14).setFill()
        fill.fill()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        ink.setStroke()
        path.stroke()

        text(fmtCPU(hi), NSPoint(x: plot.maxX + 6, y: plot.maxY - 11), size: 9,
             color: .tertiaryLabelColor)
        text("0%", NSPoint(x: plot.maxX + 6, y: plot.minY), size: 9, color: .tertiaryLabelColor)
        let secs = Double(values.count - 1) * interval
        text(secs >= 90 ? "last \(Int((secs / 60).rounded())) min" : "last \(Int(secs))s",
             NSPoint(x: 2, y: 1), size: 9, color: .tertiaryLabelColor)
        text("peak \(fmtCPU(peak))", NSPoint(x: plot.maxX - 64, y: 1), size: 9,
             color: .tertiaryLabelColor)
    }
}

// MARK: - the window

final class DetailWindow: NSWindowController, NSWindowDelegate {

    /// Sends the signal. Returns an error message, or nil on success.
    var onKill: ((ProcSample, Int32) -> String?)?
    var onRefresh: (() -> Void)?

    /// The process this window is about. Identity is the pid and the start
    /// time together, so the window cannot silently start describing whatever
    /// inherited the number.
    let pid: pid_t
    private let startedMicros: UInt64

    private var proc: ProcSample?
    /// What the main button signals: the process, or its parent when the
    /// process is a zombie.
    private var target: ProcSample?
    /// The parent as of the last update, so the Kill Parent button acts on what
    /// its title says rather than on whatever the next sample brings.
    private var parentOfRecord: ProcSample?
    private let grace: TimeInterval = 3
    private var termSent: Date?

    // MARK: views

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let spark = SparkView()
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let states = NSTextField(labelWithString: "")
    private let why = NSTextField(labelWithString: "")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let killButton = NSButton(title: "Kill", target: nil, action: nil)
    private let parentButton = NSButton(title: "Kill Parent", target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    /// The fact rows, in the order they are added, so they can be filled by
    /// name rather than by index.
    private var facts: [String: NSTextField] = [:]
    private static let factOrder = ["Path", "Bundle", "Parent", "Started", "Memory",
                                    "Disk", "Wake-ups", "Threads", "Open files"]

    init(_ p: ProcSample) {
        pid = p.pid
        startedMicros = p.startedMicros
        proc = p
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: INNER + PAD * 2, height: 560),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(p.name) (\(p.pid))"
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, size: CGFloat = 12, color: NSColor = .labelColor,
                       mono: Bool = false, wrap: CGFloat? = nil) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
                      : .systemFont(ofSize: size)
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

    private func section(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .boldSystemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: PAD, bottom: 16, right: PAD)
        stack.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 17, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(title)

        subtitle.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(subtitle)

        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        spark.heightAnchor.constraint(equalToConstant: 54).isActive = true
        stack.addArrangedSubview(spark)

        // --- the facts, as a grid so the values line up under each other
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for key in Self.factOrder {
            let k = label(key, size: 11, color: .secondaryLabelColor)
            let v = label("\u{2013}", size: 11, mono: true, wrap: INNER - 110)
            facts[key] = v
            grid.addRow(with: [k, v])
        }
        stack.addArrangedSubview(grid)

        // --- states, in words
        stack.addArrangedSubview(section("State"))
        states.font = .systemFont(ofSize: 11)
        states.textColor = .secondaryLabelColor
        states.lineBreakMode = .byWordWrapping
        states.maximumNumberOfLines = 0
        states.preferredMaxLayoutWidth = INNER
        states.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(states)

        // --- why it is listed
        stack.addArrangedSubview(section("Why it is listed"))
        why.font = .systemFont(ofSize: 11)
        why.textColor = .secondaryLabelColor
        why.lineBreakMode = .byWordWrapping
        why.maximumNumberOfLines = 0
        why.preferredMaxLayoutWidth = INNER
        why.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(why)

        // --- the command line, selectable, and wrapped rather than cut at 700
        // characters the way the table's tooltip has to be: the part that says
        // which of six helpers this is tends to be the last argument.
        //
        // Capped at twelve lines so one Electron process cannot make the window
        // taller than the screen. Copy Command Line copies the whole thing
        // regardless -- the cap is on what is drawn, not on what is held.
        stack.addArrangedSubview(section("Command line"))
        command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        command.textColor = .labelColor
        command.isSelectable = true
        command.maximumNumberOfLines = 12
        command.preferredMaxLayoutWidth = INNER
        command.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(command)

        // --- actions
        for b in [killButton, parentButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
        }
        killButton.action = #selector(killClicked)
        parentButton.action = #selector(killParentClicked)
        let copy = NSButton(title: "Copy Command Line", target: self, action: #selector(copyCommand))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealPath))
        for b in [copy, reveal] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
        }
        let close = NSButton(title: "Close", target: self, action: #selector(close_))
        stack.addArrangedSubview(row([killButton, parentButton, copy, reveal, NSView(), close]))

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = INNER
        note.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(note)

        for v in stack.arrangedSubviews {
            v.setContentHuggingPriority(.required, for: .vertical)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        window?.minSize = NSSize(width: INNER + PAD * 2, height: 420)
    }

    // MARK: - live data

    /// Pushed by the app on its tick. `proc` being nil means the process has
    /// gone, which the window says rather than freezing on its last reading.
    func update(_ given: ProcSample?, chain: [ProcSample], flag: ProcTracker.Flag?,
                trace: [Double], poll: TimeInterval, termSent: Date?) {
        // Identity is the pid and the start time together. A pid recycled while
        // this window was open would otherwise have it quietly describing a
        // different process under the same title.
        let p = given?.startedMicros == startedMicros ? given : nil
        proc = p
        self.termSent = termSent
        let parent = chain.first
        parentOfRecord = parent
        target = p.flatMap { killTarget($0, parent: parent) }

        guard let p else {
            subtitle.stringValue = "has exited"
            subtitle.textColor = .systemGreen
            killButton.isEnabled = false
            parentButton.isEnabled = false
            spark.update(trace, interval: poll)
            return
        }

        title.stringValue = p.name
        subtitle.textColor = .secondaryLabelColor
        var head: [String] = ["pid \(p.pid)"]
        if p.isZombie {
            head.append("zombie")
        } else {
            head.append("CPU \(fmtCPU(p.cpu))")
            if p.writeRate >= 512 { head.append("writing \(fmtRate(p.writeRate))") }
        }
        head.append("running \(fmtAge(p.age))")
        if let n = p.windows { head.append("\(n) window\(n == 1 ? "" : "s")") }
        subtitle.stringValue = head.joined(separator: "     ")

        spark.update(trace, interval: poll)

        // The facts.
        facts["Path"]?.stringValue = p.path.isEmpty
            ? "\u{2013} (a zombie has no address space left to read one from)" : p.path
        facts["Bundle"]?.stringValue = bundleID(p.pid) ?? "\u{2013}"
        facts["Parent"]?.stringValue = chain.isEmpty
            ? "launchd (1)"
            : chain.map { "\($0.name) (\($0.pid))" }.joined(separator: "  \u{2190}  ")
        facts["Started"]?.stringValue = "\(fmtWhen(p.started))   \u{2014}   \(fmtAge(p.age)) ago"
        facts["Memory"]?.stringValue = p.isZombie ? "\u{2013}" : fmtBytes(p.memory)
        facts["Disk"]?.stringValue = p.isZombie ? "\u{2013}"
            : "writing \(fmtRate(p.writeRate))   \u{00B7}   reading \(fmtRate(p.readRate))"
        // The energy figure, in the units the kernel actually reports. A
        // process can be cheap on CPU and still never let the package idle,
        // which is what empties a battery.
        facts["Wake-ups"]?.stringValue = p.isZombie ? "\u{2013}"
            : "\(fmtWakeups(p.wakeupRate)) idle wake-ups"
        facts["Threads"]?.stringValue = threadCount(p.pid).map(String.init) ?? "\u{2013}"
        facts["Open files"]?.stringValue = fdCount(p.pid).map(String.init) ?? "\u{2013}"

        // The states, each spelled out. Only the ones that hold: a list of four
        // with three "no"s in it says nothing.
        var lines: [String] = []
        if p.isZombie { lines.append("Zombie \u{2014} " + WatchState.zombie.explanation) }
        if p.isOrphan { lines.append("Orphan \u{2014} " + WatchState.orphan.explanation) }
        if p.isWindowless == true {
            lines.append("No window \u{2014} " + WatchState.windowless.explanation)
        }
        if p.responsive == false {
            lines.append("Not responding \u{2014} " + WatchState.unresponsive.explanation)
        }
        if lines.isEmpty {
            lines.append(p.isGUIApp
                ? "Nothing unusual. It is an app, it is answering, and it has windows."
                : "Nothing unusual. It is not an app, so windows and responsiveness do not apply to it.")
            if p.isGUIApp && p.responsive == nil {
                lines.append("Windows and responsiveness are not being checked \u{2014} "
                           + "turn on Inspect Apps in the menu to check them.")
            }
        }
        states.stringValue = lines.joined(separator: "\n")

        if let f = flag {
            // A rule named after its only condition -- "Zombie", whose summary
            // is "zombie" -- would otherwise read "Zombie: zombie."
            let named = f.rule.name.lowercased() == f.rule.summary.lowercased()
                ? f.rule.name
                : "\(f.rule.name): \(f.rule.summary)"
            why.stringValue = f.sustained
                ? "\(named). Held for \(fmtAge(f.heldFor))."
                : "\(named). Held for \(fmtAge(f.heldFor)) of the "
                  + "\(fmtAge(f.rule.sustain)) it needs, so it is counting rather than flagged."
            why.textColor = f.sustained ? .systemRed : .systemOrange
        } else {
            why.stringValue = "No rule flags it. This is the detail of a process you asked about."
            why.textColor = .secondaryLabelColor
        }

        let args = procArgs(p.pid)
        command.stringValue = args.isEmpty
            ? (p.path.isEmpty ? "\u{2013}" : p.path)
            : args.joined(separator: " ")

        styleKillButton(killButton, for: p, target: target, termSentAt: termSent, grace: grace)
        if let parent, killability(of: parent) == .yes, !p.isZombie {
            parentButton.isHidden = false
            parentButton.title = "Kill \(parent.name) (\(parent.pid))"
            parentButton.isEnabled = true
            parentButton.toolTip = "Kill a helper and its app starts another. Kill the app and "
                                 + "both are gone."
        } else {
            // On a zombie the one useful action is already on the main button.
            parentButton.isHidden = true
        }
    }

    // MARK: - actions

    private func send(_ p: ProcSample, _ sig: Int32) {
        if let err = onKill?(p, sig) { fail(err); return }
        say("Sent \(sig == SIGKILL ? "SIGKILL" : "SIGTERM") to \(p.name) (\(p.pid)).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.onRefresh?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 0.3) { [weak self] in self?.onRefresh?() }
    }

    @objc private func killClicked() {
        guard let target else { return }
        let force = termSent.map { Date().timeIntervalSince($0) > grace } ?? false
        send(target, force ? SIGKILL : SIGTERM)
    }

    @objc private func killParentClicked() {
        guard let parent = parentOfRecord, killability(of: parent) == .yes else { return }
        send(parent, SIGTERM)
    }

    @objc private func copyCommand() {
        let text = command.stringValue
        guard text != "\u{2013}", !text.isEmpty else {
            fail("There is no command line left to copy.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say("Copied.")
    }

    @objc private func revealPath() {
        guard let p = proc, !p.path.isEmpty else {
            fail("There is no path to show: a zombie has no address space left to read one from.")
            return
        }
        var target = p.path
        if let r = p.path.range(of: ".app/") { target = String(p.path[..<r.lowerBound]) + ".app" }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
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
