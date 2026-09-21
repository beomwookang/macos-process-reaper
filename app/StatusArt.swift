//
// Drawn status: the menu bar mark, and one flagged process as a row.
//
// The mark has one job -- calm normally, red when something is flagged -- but it
// carries a number while it is at it: the chip fills with how busy the machine
// is, which is the denominator for the count beside it. Eight flagged processes
// on an idle machine and eight on a saturated one are different situations, and
// the mark should not read the same in both.
//

import AppKit

// MARK: - menu bar mark

/// What the mark is saying. `holding` is the state between the two: a rule's
/// conditions are met and its sustain is still counting, so something is
/// building but nothing is yet worth a person's attention.
enum MarkState: Equatable {
    case calm
    case holding(Int)
    case flagged(Int)
    /// Watching is suspended. Drawn faint, because the promise the mark makes
    /// is that calm means nothing to report -- and a paused watch has nothing
    /// to report for a different reason, which it has to admit to.
    case paused
}

private let MARK_H: CGFloat = 18
private let CHIP_W: CGFloat = 15

/// Fraction of the way from `lo` to `hi`, clamped.
private func frac(_ v: Double, _ lo: Double, _ hi: Double) -> CGFloat {
    guard hi > lo else { return 0 }
    return CGFloat(min(max((v - lo) / (hi - lo), 0), 1))
}

/// The whole menu bar item as one image: the chip, and the count when there is
/// something to count.
///
/// Drawn rather than handed to the button as an image plus a title. The button
/// centres a title by its own reckoning, and against a 15pt image that
/// reckoning leaves the digit sitting a pixel and a half too high.
func statusMark(_ state: MarkState, load: SystemLoad?) -> NSImage {
    let label: NSString?
    let ink: NSColor
    let template: Bool
    switch state {
    case .calm:
        label = nil
        // Opaque black, and a template: the system uses the alpha channel and
        // draws the mark in whatever ink the menu bar is using, so it follows a
        // light/dark switch and a tinted desktop without being told.
        ink = .black
        template = true
    case .paused:
        label = nil
        // Still a template, so it still follows the bar's ink -- just faintly.
        // The faintness is `dim` below, not an alpha on this colour: drawChip
        // sets its own alphas per element, and an alpha here would be
        // overwritten and silently ignored.
        ink = .black
        template = true
    case .holding:
        label = nil
        ink = .systemOrange
        template = false
    case .flagged(let n):
        label = "\(n)" as NSString
        ink = .systemRed
        template = false
    }

    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let gap: CGFloat = 3
    let textW = label.map { $0.size(withAttributes: attrs).width } ?? 0
    let width = CHIP_W + (label == nil ? 0 : gap + textW)

    // A template image's alpha is the mask, so drawing the whole mark at a
    // fraction of its opacity is what makes a faint mark rather than a grey one.
    let dim: CGFloat = state == .paused ? 0.34 : 1
    let img = NSImage(size: NSSize(width: width, height: MARK_H), flipped: false) { _ in
        drawChip(at: .zero, ink: ink, load: load, dim: dim)
        if let label {
            // A stated baseline rather than a centred rect: an 11pt digit box is
            // about 13pt tall, and centring the box leaves the glyph high.
            label.draw(at: NSPoint(x: CHIP_W + gap, y: 3.5), withAttributes: attrs)
        }
        return true
    }
    img.isTemplate = template
    return img
}

/// The chip: a rounded rectangle standing for the machine, filled from the
/// bottom with how much of it is busy. Outline always, fill only as far as the
/// load goes.
private func drawChip(at o: NSPoint, ink: NSColor, load: SystemLoad?, dim: CGFloat = 1) {
    let r = NSRect(x: o.x + 1.5, y: o.y + 2.5, width: CHIP_W - 3, height: MARK_H - 5)
    let radius: CGFloat = 3

    let outline = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    outline.lineWidth = 1.4
    ink.withAlphaComponent(0.9 * dim).setStroke()
    outline.stroke()

    // Two legs a side, so the outline reads as a chip and not as a text field.
    ink.withAlphaComponent(0.9 * dim).setFill()
    for dy in [r.height * 0.3, r.height * 0.62] {
        for x in [r.minX - 2.2, r.maxX + 0.4] {
            NSBezierPath(rect: NSRect(x: x, y: r.minY + dy, width: 1.8, height: 1.3)).fill()
        }
    }

    guard let cpu = load?.cpu, cpu > 0.02 else { return }
    let inner = r.insetBy(dx: 2.2, dy: 2.2)
    let h = inner.height * frac(cpu, 0, 1)
    guard h > 0.6 else { return }
    let filled = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: h)
    // Clipped to the chip's own rounding, so a full fill does not square off
    // the corners the outline just drew.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: inner, xRadius: 1.6, yRadius: 1.6).setClip()
    ink.withAlphaComponent(0.55 * dim).setFill()
    NSBezierPath(rect: filled).fill()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - the kill button

/// The button's states, shared by the menu rows and the window so the same
/// process never reads differently in the two places.
///
/// `target` is what the button will signal, which for a zombie is its parent.
func styleKillButton(_ b: NSButton, for p: ProcSample, target: ProcSample?,
                     termSentAt: Date?, grace: TimeInterval) {
    b.contentTintColor = nil

    switch killability(of: p) {
    case .system:
        b.title = "Kill"
        b.isEnabled = false
        b.toolTip = "Part of macOS. Ending it would log you out or achieve nothing, "
                  + "so it is not offered."
        return
    case .zombie:
        guard let target else {
            b.title = "Kill"
            b.isEnabled = false
            b.toolTip = "Already dead, and nothing here can clear it: it holds no CPU and no "
                      + "memory, cannot be signalled, and its parent cannot be either. It will "
                      + "go when its parent does."
            return
        }
        b.title = "Parent"
        b.isEnabled = termSentAt == nil || Date().timeIntervalSince(termSentAt!) > grace
        b.contentTintColor = termSentAt == nil ? nil : .systemRed
        b.toolTip = "\(p.name) is already dead: it holds nothing and cannot be signalled, it is "
                  + "a row in the process table waiting to be collected. Ending its parent "
                  + "\(target.name) (\(target.pid)) is what collects it."
        return
    case .yes:
        break
    }

    if let t = termSentAt {
        let ago = Date().timeIntervalSince(t)
        if ago > grace {
            b.title = "Force"
            b.isEnabled = true
            b.contentTintColor = .systemRed
            b.toolTip = "Still running \(fmtAge(ago)) after SIGTERM. Force sends SIGKILL, "
                      + "which it cannot ignore."
        } else {
            b.title = "Sent"
            b.isEnabled = false
            b.toolTip = "SIGTERM sent. Waiting for it to exit."
        }
    } else {
        b.title = "Kill"
        b.isEnabled = true
        b.toolTip = "Send SIGTERM."
    }
}

// MARK: - one process as a row in the menu

/// The name over its numbers, and the button that ends it. Two lines rather
/// than a table row: at menu width a single line would leave the name a dozen
/// characters.
final class ProcessRowView: NSView {
    static let W: CGFloat = 320
    static let H: CGFloat = 38

    private let name = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    let button = NSButton(title: "Kill", target: nil, action: nil)
    private(set) var proc: ProcSample?
    /// What the button signals. The same as `proc`, except on a zombie's row.
    private(set) var target: ProcSample?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.W, height: Self.H))
        // Let the menu widen the row to its own width; the constraints below
        // keep the button on the right edge and the text off it.
        autoresizingMask = [.width]

        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        info.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        // The text gives way, never the button: a long name truncates rather
        // than pushing the button off the edge or widening the row.
        for t in [name, info] {
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)

        for v in [name, info, button] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            info.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            info.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 62),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ f: ProcTracker.Flag, parent: ProcSample?, termSentAt: Date?, grace: TimeInterval) {
        let p = f.proc
        proc = p
        target = killTarget(p, parent: parent)
        name.stringValue = p.name
        toolTip = "\(f.rule.name): \(f.rule.summary)" + (p.path.isEmpty ? "" : "\n\(p.path)")
        info.attributedStringValue = Self.infoLine(p, font: info.font ?? .systemFont(ofSize: 10))
        styleKillButton(button, for: p, target: target, termSentAt: termSentAt, grace: grace)
    }

    /// pid, then the numbers, unlabelled so the line fits the row. A zombie's
    /// numbers are all zero and saying "0%" of it would be a reading rather
    /// than the fact, which is that it is dead.
    static func infoLine(_ p: ProcSample, font: NSFont) -> NSAttributedString {
        let s = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor = .secondaryLabelColor) {
            s.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c]))
        }
        add("\(p.pid) \u{00B7} ")
        if p.isZombie {
            add("zombie", .systemRed)
            add(" \u{00B7} dead for \(fmtAge(p.age))")
            return s
        }
        add(fmtCPU(p.cpu), loadColor(p.cpu, quiet: true))
        add(" \u{00B7} \(fmtBytes(p.memory)) \u{00B7} \(fmtAge(p.age))")
        return s
    }

    /// An error where the numbers were: an alert would close the menu, and the
    /// row is where the person is looking.
    func showError(_ msg: String) {
        info.attributedStringValue = NSAttributedString(string: msg, attributes: [
            .font: info.font ?? .systemFont(ofSize: 10), .foregroundColor: NSColor.systemRed,
        ])
    }
}
