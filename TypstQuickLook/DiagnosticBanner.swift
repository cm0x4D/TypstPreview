import AppKit

/// Floating bar at the bottom of the source view: the current diagnostic's message,
/// previous/next navigation when there are several, and a button for the full compiler output.
final class DiagnosticBanner: NSVisualEffectView {
    var onSelect: ((Int) -> Void)?
    var onShowDetails: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private var markers: [SourceMarker] = []
    private(set) var index = 0

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(revealCurrent)))
        label.toolTip = "Show in source"

        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.setContentHuggingPriority(.required, for: .horizontal)

        configure(previous, symbol: "chevron.up", tip: "Previous problem", action: #selector(goPrevious))
        configure(next, symbol: "chevron.down", tip: "Next problem", action: #selector(goNext))

        let details = NSButton(title: "Details", target: self, action: #selector(showDetails))
        details.bezelStyle = .rounded
        details.controlSize = .small
        details.toolTip = "Show the complete compiler output"
        details.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, counter, previous, next, details])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func show(_ markers: [SourceMarker]) {
        self.markers = markers
        select(0, notify: false)
    }

    private func select(_ newIndex: Int, notify: Bool) {
        guard !markers.isEmpty else { return }
        index = (newIndex + markers.count) % markers.count
        let marker = markers[index]
        let color = SourceTextView.color(for: marker.severity)
        let symbol = marker.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: marker.severity.rawValue)
        icon.contentTintColor = color
        layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        label.stringValue = "Line \(marker.line): \(marker.message)"
        counter.stringValue = "\(index + 1) of \(markers.count)"
        let multiple = markers.count > 1
        counter.isHidden = !multiple
        previous.isHidden = !multiple
        next.isHidden = !multiple
        if notify { onSelect?(index) }
    }

    @objc private func goPrevious() { select(index - 1, notify: true) }
    @objc private func goNext() { select(index + 1, notify: true) }
    @objc private func revealCurrent() { onSelect?(index) }
    @objc private func showDetails() { onShowDetails?() }
}
