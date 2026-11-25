import AppKit

/// A centered information page: icon, title, explanation, optional copyable
/// shell commands and an optional monospaced details box (compiler diagnostics).
final class MessageView: NSView {
    struct Command {
        let caption: String
        let command: String
    }

    init(symbol: String, tint: NSColor, title: String, message: String,
         commands: [Command] = [], footnote: String? = nil, details: String? = nil) {
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            let imageView = NSImageView(image: image.withSymbolConfiguration(config) ?? image)
            imageView.contentTintColor = tint
            stack.addArrangedSubview(imageView)
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isSelectable = true
        messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        stack.addArrangedSubview(messageLabel)

        for command in commands {
            stack.addArrangedSubview(Self.commandRow(command))
        }

        if let footnote {
            let label = NSTextField(wrappingLabelWithString: footnote)
            label.alignment = .center
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 11)
            label.isSelectable = true
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
            stack.addArrangedSubview(label)
        }

        var detailsScroll: NSScrollView?
        if let details, !details.isEmpty {
            let scroll = Self.detailsView(details)
            stack.addArrangedSubview(scroll)
            detailsScroll = scroll
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 60),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
        ])
        if let detailsScroll {
            let width = detailsScroll.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48)
            width.priority = .defaultHigh
            width.isActive = true
            detailsScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 760).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func commandRow(_ command: Command) -> NSView {
        let caption = NSTextField(labelWithString: command.caption)
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor

        let field = NSTextField(labelWithString: command.command)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.isSelectable = true

        let copy = CopyButton(text: command.command)

        let box = NSStackView(views: [field, copy])
        box.orientation = .horizontal
        box.spacing = 12
        box.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor

        let row = NSStackView(views: [caption, box])
        row.orientation = .vertical
        row.alignment = .centerX
        row.spacing = 6
        return row
    }

    private static func detailsView(_ text: String) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.string = text
        }
        return scroll
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class CopyButton: NSButton {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        isBordered = false
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        toolTip = "Copy to clipboard"
        target = self
        action = #selector(copyText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }
}
