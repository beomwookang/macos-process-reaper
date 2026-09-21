//
// Makes assets/mark-states.png: every state of the menu bar mark, side by side.
//
// In the repository, and the only thing that writes that file, because it has
// been wrong twice for the same reason. The image is drawn by the app's own
// statusMark, so leaving the generator outside the repository let the picture
// drift from the code -- and having a second copy of this code inside a
// throwaway screenshot harness let a fixed version of the file be overwritten
// by the broken one it had replaced.
//
//   make mark-states
//
// Transparent, with no panel behind the marks. Two earlier versions had one --
// first a strip of menu bar behind each chip, then a flat dark field behind all
// of them -- and both read, on a white README page, as an odd rectangle sitting
// in the middle of the document. What the image has to show is four glyphs and
// which is which; a background only competes with the page it lands on.
//
// Which means the template marks cannot be tinted the near-white a dark menu
// bar would use, because the page underneath may be white. They are drawn in a
// mid grey that holds up against both, and paused stays visibly fainter because
// the faintness is alpha rather than a lighter colour.
//
// Every mark is drawn at the enlarged size, so the bezier paths are stroked at
// that size and the edges stay clean. That has to include the tinted ones: a
// template's tinted copy built at the mark's natural fifteen by eighteen points
// and then scaled up is a small bitmap magnified, and it showed -- calm and
// paused came out visibly softer than the two coloured states beside them,
// which never went through the tint at all.
//

import AppKit

@main
enum MarkStates {
    /// A magnified view, so the shape is legible in a README.
    static let zoom = 6
    static let load = SystemLoad(cpu: 0.35, ncpu: 10, gpu: 30,
                                 memUsed: 8 << 30, memTotal: 24 << 30)
    static let states: [(MarkState, String)] = [
        (.calm, "calm"), (.holding(2), "holding"), (.flagged(3), "flagged"), (.paused, "paused"),
    ]

    /// Draws one mark into `r` on the current context, tinting it there if it
    /// is a template: the system draws a template in the menu bar's ink, and
    /// drawing the mask as it comes shows nothing at all.
    ///
    /// The tint is applied at `r`'s size, not at the mark's own. Building the
    /// tinted copy small and scaling it up is what made calm and paused softer
    /// than their neighbours.
    static func draw(_ s: MarkState, in r: NSRect) {
        let img = statusMark(s, load: load)
        guard img.isTemplate else {
            img.draw(in: r)
            return
        }
        let tint = NSImage(size: r.size)
        tint.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: r.size))
        // Mid grey, not the near-white a dark menu bar draws with: this image
        // sits on a page that may be either colour.
        NSColor(calibratedWhite: 0.45, alpha: 1).set()
        // Inside its own image, which starts transparent: sourceAtop against a
        // context that already has a background paints the background too.
        NSRect(origin: .zero, size: r.size).fill(using: .sourceAtop)
        tint.unlockFocus()
        tint.draw(in: r)
    }

    static func main() {
        _ = NSApplication.shared
        guard CommandLine.arguments.count > 1 else {
            print("usage: mark-states <output directory>")
            exit(2)
        }
        let out = CommandLine.arguments[1]

        // The natural sizes, for the layout. Nothing is rasterised yet.
        let sizes = states.map { statusMark($0.0, load: load).size }
        // One cell wide enough for the widest mark, so they sit on a common grid.
        let markW = sizes.map { $0.width }.max()! * CGFloat(zoom)
        let markH = sizes.map { $0.height }.max()! * CGFloat(zoom)
        let padX: CGFloat = 46, padTop: CGFloat = 34, labelGap: CGFloat = 26
        let padBottom: CGFloat = 30
        let cellW = markW + padX * 2
        let W = cellW * CGFloat(states.count)
        let H = padTop + markH + labelGap + padBottom

        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2),
                                      pixelsHigh: Int(H * 2), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                      bitsPerPixel: 0)!
        canvas.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        // Cleared to transparent, explicitly: the bitmap is allocated
        // uninitialised, and whatever happens to be in that memory is what
        // shows through otherwise.
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        for (i, pair) in states.enumerated() {
            let w = sizes[i].width * CGFloat(zoom), h = sizes[i].height * CGFloat(zoom)
            let x = cellW * CGFloat(i) + (cellW - w) / 2
            draw(pair.0, in: NSRect(x: x, y: H - padTop - h, width: w, height: h))

            let label = pair.1 as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                // Readable on a white page and on a dark one.
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
            ]
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: cellW * CGFloat(i) + (cellW - sz.width) / 2,
                                   y: padBottom - 6), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        let path = "\(out)/mark-states.png"
        guard let data = canvas.representation(using: .png, properties: [:]) else {
            print("could not encode the image")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("could not write \(path): \(error)")
            exit(1)
        }
        print("wrote \(path) at \(Int(W))x\(Int(H)) points, \(states.count) states")
    }
}
