//
// About Reaper: what this is, what version, and what to send when it is wrong.
//
// An about box is usually decoration. This one earns its place with one button:
// Copy Diagnostics puts the whole of `--diagnose` on the clipboard -- the loaded
// profile, what the sampler found, what each rule made of it, and which colour
// the mark would be. A report with that pasted into it needs no follow-up
// questions, and the alternative is asking someone to run a binary inside an
// app bundle from a terminal.
//

import AppKit

private let INNER: CGFloat = 400
private let PAD: CGFloat = 24

final class AboutWindow: NSWindowController, NSWindowDelegate {

    private let note = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Diagnostics", target: nil, action: nil)
    private let stack = NSStackView()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: INNER + PAD * 2, height: 320),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "About \(APP_NAME)"
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, wrap: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.alignment = .center
        if wrap {
            t.lineBreakMode = .byWordWrapping
            t.maximumNumberOfLines = 0
            t.preferredMaxLayoutWidth = INNER
        }
        t.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        return t
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: PAD, left: PAD, bottom: PAD, right: PAD)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The bundle's own icon, asked for by resource name rather than through
        // NSApp.applicationIconImage: this is an LSUIElement app with no Dock
        // tile, and asking the application for its icon outside a bundle hands
        // back the generic document icon.
        let icon = NSImageView()
        icon.image = Bundle.main.image(forResource: "Reaper") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        stack.addArrangedSubview(icon)

        stack.addArrangedSubview(label(APP_NAME, size: 22, weight: .medium))
        stack.addArrangedSubview(label("Version \(appVersion)", size: 11,
                                       color: .secondaryLabelColor))

        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(gap)

        stack.addArrangedSubview(label(
            "A menu bar watch for the processes nobody remembers starting.",
            size: 12, wrap: true))
        stack.addArrangedSubview(label(
            "It flags them. It never kills anything for you, and there is no "
            + "setting that changes that.",
            size: 11, color: .secondaryLabelColor, wrap: true))

        let gap2 = NSView()
        gap2.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stack.addArrangedSubview(gap2)

        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .regular
        copyButton.toolTip = "Puts the loaded profile, what the sampler just found, and what each "
                           + "rule made of it on the clipboard. Paste it into a bug report."
        let repo = NSButton(title: "Source & Issues", target: self, action: #selector(openRepo))
        repo.bezelStyle = .rounded
        repo.controlSize = .regular
        let buttons = NSStackView(views: [copyButton, repo])
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = INNER
        note.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(note)
        resetNote()

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
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: INNER + PAD * 2, height: stack.fittingSize.height))
    }

    private func resetNote() {
        note.textColor = .secondaryLabelColor
        note.stringValue = "MIT. No daemon, no helper, nothing running as root."
    }

    /// Sampling twice with a pause between is what makes the CPU figures mean
    /// anything, so this takes a moment. Off the main thread, with the button
    /// disabled meanwhile, rather than freezing the window for two seconds.
    @objc private func copyDiagnostics() {
        copyButton.isEnabled = false
        note.textColor = .secondaryLabelColor
        note.stringValue = "Sampling\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = diagnosticsText()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.copyButton.isEnabled = true
                self.note.textColor = .systemGreen
                self.note.stringValue = "Copied. Paste it into an issue \u{2014} it says which "
                                      + "profile is loaded and what the rules made of this machine."
            }
        }
    }

    @objc private func openRepo() {
        if let url = URL(string: REPO_URL) { NSWorkspace.shared.open(url) }
    }

    func windowWillClose(_ n: Notification) { resetNote() }
}
