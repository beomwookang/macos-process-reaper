//
// Checks for the drawn parts: the menu bar mark, the row's info line, and the
// three states of the kill button.
//
// No window is created. The mark and the row are drawn into a bitmap instead,
// which is enough to catch the failures that matter here -- a mark that comes
// out empty, a template flag on the wrong state, a button whose title does not
// match what clicking it would do -- and it runs on a machine with no screen.
//

import AppKit

enum ViewTests {
    static func run(_ check: (Bool, String, String) -> Void) {
        mark(check)
        rows(check)
        buttons(check)
        columns(check)
        drawing(check)
    }

    private static let load = SystemLoad(cpu: 0.5, ncpu: 10, gpu: 12,
                                         memUsed: 8 << 30, memTotal: 24 << 30)

    // MARK: - the mark

    private static func mark(_ check: (Bool, String, String) -> Void) {
        let calm = statusMark(.calm, load: load)
        let holding = statusMark(.holding(2), load: load)
        let flagged = statusMark(.flagged(3), load: load)

        // Calm is a template so the system draws it in the menu bar's own ink;
        // the other two carry a colour that a template would throw away.
        check(calm.isTemplate, "the calm mark is a template, so it follows the menu bar", "")
        check(!holding.isTemplate && !flagged.isTemplate,
              "the amber and red marks are not templates: their colour is the point", "")

        check(calm.size.height == 18 && holding.size.height == 18 && flagged.size.height == 18,
              "every mark is the height of the menu bar", "\(calm.size) \(flagged.size)")
        check(calm.size.width == holding.size.width,
              "holding adds no digit, so it is the same width as calm",
              "\(calm.size.width) vs \(holding.size.width)")
        check(flagged.size.width > calm.size.width,
              "flagged carries a count, so it is wider", "\(flagged.size.width)")
        check(statusMark(.flagged(17), load: load).size.width
                > statusMark(.flagged(3), load: load).size.width,
              "a two-digit count is wider than a one-digit count", "")

        // The load is a fill, so it must not change the size of anything.
        check(statusMark(.calm, load: nil).size == calm.size,
              "a mark with no load reading is the same size as one with", "")

        // Paused is the calm glyph, faint, and still a template so it keeps
        // following the menu bar's own ink.
        let paused = statusMark(.paused, load: load)
        check(paused.isTemplate, "the paused mark is still a template", "")
        check(paused.size == calm.size, "and the same size as calm", "\(paused.size)")
    }

    // MARK: - the row's info line

    private static func rows(_ check: (Bool, String, String) -> Void) {
        let font = NSFont.systemFont(ofSize: 10)
        let live = ProcessRowView.infoLine(testProc(pid: 42, cpu: 350, memMB: 900, ageH: 2),
                                           font: font).string
        check(live.contains("42") && live.contains("350%") && live.contains("900 MB"),
              "a live row's line carries the pid, the CPU and the footprint", live)

        // A zombie's numbers are all zero, and printing "0%" of it would be a
        // reading where the fact is that it is dead.
        let dead = ProcessRowView.infoLine(testProc(pid: 43, ageH: 0.5, path: "", zombie: true),
                                           font: font).string
        check(dead.contains("zombie") && !dead.contains("%") && !dead.contains("MB"),
              "a zombie's line says zombie and quotes no numbers", dead)
        check(dead.contains("dead for"), "a zombie's line says how long it has been dead", dead)

        let head = ProcessWindow.headlineText(load)
        check(head.contains("10 cores") && head.contains("GPU 12%") && head.contains("of 24.0 GB"),
              "the headline names the cores, the GPU and the memory", head)
        check(ProcessWindow.headlineText(SystemLoad(cpu: nil, ncpu: 8, gpu: nil,
                                                    memUsed: 1 << 30, memTotal: 8 << 30))
                .contains("GPU \u{2013}"),
              "a missing GPU figure is a dash, not a zero", "")
    }

    // MARK: - the kill button

    private static func buttons(_ check: (Bool, String, String) -> Void) {
        let b = NSButton(title: "", target: nil, action: nil)

        let live = testProc(pid: 5)
        styleKillButton(b, for: live, target: live, termSentAt: nil, grace: 3)
        check(b.title == "Kill" && b.isEnabled, "an ordinary process offers Kill", b.title)

        styleKillButton(b, for: live, target: live, termSentAt: Date(), grace: 3)
        check(b.title == "Sent" && !b.isEnabled, "just after SIGTERM the button waits", b.title)

        styleKillButton(b, for: live, target: live, termSentAt: Date() - 10, grace: 3)
        check(b.title == "Force" && b.isEnabled,
              "a process still there after the grace period offers Force", b.title)

        let sys = testProc(pid: 5, path: "/usr/libexec/trustd")
        styleKillButton(b, for: sys, target: nil, termSentAt: nil, grace: 3)
        check(b.title == "Kill" && !b.isEnabled && (b.toolTip ?? "").contains("macOS"),
              "a system process shows a disabled button and says why", b.title)

        // The one case where the button acts on something other than its row.
        let zomb = testProc(pid: 5, ppid: 400, path: "", zombie: true)
        let parent = testProc(pid: 400)
        styleKillButton(b, for: zomb, target: killTarget(zomb, parent: parent),
                        termSentAt: nil, grace: 3)
        check(b.title == "Parent" && b.isEnabled,
              "a zombie's button offers its parent, which is the only thing that clears it", b.title)
        check((b.toolTip ?? "").contains("400"),
              "and names the parent it would signal, so the button cannot surprise anyone",
              b.toolTip ?? "")

        styleKillButton(b, for: zomb, target: nil, termSentAt: nil, grace: 3)
        check(!b.isEnabled && (b.toolTip ?? "").contains("parent cannot"),
              "a zombie with no reachable parent is a dead end, and says so", b.toolTip ?? "")
    }

    // MARK: - column arithmetic

    /// The table narrows only its first column, so a set of fixed widths that
    /// sums past the table clips the last one instead. That is a silent
    /// failure -- a header reading "Outcor" -- so it is checked rather than
    /// eyeballed.
    static func columns(_ check: (Bool, String, String) -> Void) {
        for (what, cols) in [("live", ProcessWindow.liveColumnWidths),
                             ("history", ProcessWindow.historyColumnWidths)] {
            let sum = cols.reduce(0, +)
            check(sum < ProcessWindow.tableWidth,
                  "the \(what) columns fit the table",
                  "\(Int(sum)) of \(Int(ProcessWindow.tableWidth))")
        }
    }

    // MARK: - actually drawing it

    /// Renders into a bitmap. The mark is built with a lazy drawing handler, so
    /// nothing in it runs until something asks for pixels -- which means a mark
    /// that throws or comes out blank would otherwise pass every check above.
    private static func render(_ img: NSImage) -> NSBitmapImageRep? {
        let w = Int(img.size.width.rounded()), h = Int(img.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func inked(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 { n += 1 }
            }
        }
        return n
    }

    private static func drawing(_ check: (Bool, String, String) -> Void) {
        for (name, state) in [("calm", MarkState.calm), ("holding", .holding(2)),
                              ("flagged", .flagged(3)), ("paused", .paused)] {
            guard let rep = render(statusMark(state, load: load)) else {
                check(false, "the \(name) mark renders at all", "no bitmap context")
                continue
            }
            let n = inked(rep)
            check(n > 20, "the \(name) mark draws something", "\(n) inked pixels")
            check(n < rep.pixelsWide * rep.pixelsHigh,
                  "the \(name) mark is a glyph, not a filled block", "\(n) inked pixels")
        }

        // The fill is the load, so an idle machine and a busy one must not draw
        // the same mark.
        let idle = render(statusMark(.calm, load: SystemLoad(cpu: 0, ncpu: 10, gpu: nil,
                                                             memUsed: 1, memTotal: 2)))
        let busy = render(statusMark(.calm, load: SystemLoad(cpu: 1, ncpu: 10, gpu: nil,
                                                             memUsed: 1, memTotal: 2)))
        if let idle, let busy {
            check(inked(busy) > inked(idle),
                  "the mark's fill follows the load", "\(inked(idle)) vs \(inked(busy))")
        } else {
            check(false, "the mark renders at both ends of the load range", "")
        }

        // Paused has to be visibly fainter, or it says the same thing as calm.
        func alphaWeight(_ s: MarkState) -> Double {
            guard let rep = render(statusMark(s, load: load)) else { return -1 }
            var total = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    total += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            return total
        }
        let calmWeight = alphaWeight(.calm), pausedWeight = alphaWeight(.paused)
        check(pausedWeight > 0 && pausedWeight < calmWeight * 0.7,
              "the paused mark is drawn markedly fainter than the calm one",
              "\(Int(calmWeight)) vs \(Int(pausedWeight))")
    }
}
