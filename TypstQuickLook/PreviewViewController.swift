import AppKit
import PDFKit
import Quartz
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypstQuickLook", category: "preview")

final class PreviewViewController: NSViewController, QLPreviewingController {
    private enum Mode: Int {
        case rendered = 0
        case source = 1
    }

    private static let modeDefaultsKey = "SelectedMode"
    private static let toolbarInset: CGFloat = 48

    private let container = NSView()
    private let sourceParts = SourceTextView.makeScrollable()
    private var sourceScrollView: NSScrollView { sourceParts.0 }
    private var sourceTextView: SourceTextView { sourceParts.1 }
    private let diagnosticBanner = DiagnosticBanner()
    private var markers: [SourceMarker] = []
    private let renderedContainer = NSView()
    private let modeControl = NSSegmentedControl(
        labels: ["Preview", "Source"], trackingMode: .selectOne, target: nil, action: nil)

    private var compileTask: Task<Void, Never>?

    private var mode: Mode = .rendered {
        didSet { updateVisibleMode() }
    }

    // MARK: View setup

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        root.wantsLayer = true
        view = root
        preferredContentSize = NSSize(width: 800, height: 900)

        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)

        for content in [renderedContainer, sourceScrollView] {
            content.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        configureSourceView()
        let toolbar = makeToolbar()
        root.addSubview(toolbar)

        diagnosticBanner.isHidden = true
        diagnosticBanner.onSelect = { [weak self] index in self?.revealMarker(at: index) }
        diagnosticBanner.onShowDetails = { [weak self] in self?.setMode(.rendered) }
        root.addSubview(diagnosticBanner)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            diagnosticBanner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            diagnosticBanner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            diagnosticBanner.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 14),
            diagnosticBanner.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            diagnosticBanner.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
        ])

        let stored = UserDefaults.standard.object(forKey: Self.modeDefaultsKey) as? Int
        mode = stored.flatMap(Mode.init(rawValue:)) ?? .rendered
    }

    private func configureSourceView() {
        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceScrollView.borderType = .noBorder
        sourceScrollView.automaticallyAdjustsContentInsets = false
        sourceScrollView.contentInsets = NSEdgeInsets(top: Self.toolbarInset, left: 0, bottom: 0, right: 0)

        let textView = sourceTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
    }

    private func makeToolbar() -> NSView {
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .regular
        modeControl.setImage(NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Preview"), forSegment: 0)
        modeControl.setImage(NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Source"), forSegment: 1)
        modeControl.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        modeControl.setImageScaling(.scaleProportionallyDown, forSegment: 1)
        modeControl.setToolTip("Rendered PDF preview", forSegment: 0)
        modeControl.setToolTip("Typst source with syntax highlighting", forSegment: 1)
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(modeControl)

        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            modeControl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
            modeControl.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            modeControl.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])
        return pill
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard let newMode = Mode(rawValue: sender.selectedSegment) else { return }
        setMode(newMode)
    }

    /// A mode chosen by the user is remembered; automatic switches (on errors) are not.
    private func setMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
    }

    private func updateVisibleMode() {
        modeControl.selectedSegment = mode.rawValue
        renderedContainer.isHidden = mode != .rendered
        sourceScrollView.isHidden = mode != .source
        diagnosticBanner.isHidden = mode != .source || markers.isEmpty
    }

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        _ = view // make sure the view hierarchy exists

        let text = try await Task.detached(priority: .userInitiated) {
            try Self.readSource(at: url)
        }.value
        let highlighted = await Task.detached(priority: .userInitiated) {
            UncheckedBox(TypstHighlighter.highlight(text))
        }.value
        sourceTextView.textStorage?.setAttributedString(highlighted.value)

        guard let tool = TypstToolchain.locate() else {
            log.error("Neither typst nor tinymist found")
            showRendered(Self.missingToolView())
            return
        }

        showRendered(Self.progressView(tool: tool))

        // Compile after returning so Quick Look can show the source right away;
        // the rendered view is swapped in when the PDF is ready.
        compileTask = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await RenderServiceClient.compile(url, using: tool))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                log.info("Rendered \(url.lastPathComponent, privacy: .public) with \(tool.kind.rawValue, privacy: .public): \(data.count) bytes")
                if let document = PDFDocument(data: data) {
                    self.showRendered(self.makePDFView(document))
                } else {
                    self.showRendered(Self.errorView(title: "Invalid PDF",
                        message: "\(tool.kind.rawValue) produced output that could not be read as a PDF.",
                        details: nil))
                }
            case .failure(let error):
                log.error("Rendering \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.showRendered(Self.view(for: error, file: url))
                if case TypstCompileError.failed(_, _, let diagnostics) = error {
                    self.showDiagnostics(diagnostics, in: text, file: url)
                }
            }
        }
    }

    deinit {
        compileTask?.cancel()
    }

    // MARK: Diagnostics

    /// Marks the offending lines in the source and switches to it, scrolled to the first error.
    private func showDiagnostics(_ output: String, in text: String, file: URL) {
        let found = TypstDiagnostics.markers(for: TypstDiagnostics.parse(output), in: text, file: file)
        guard found.contains(where: { $0.severity == .error }) else { return } // e.g. error inside a package
        markers = found
        log.info("Marked \(found.count) problem(s) in \(file.lastPathComponent, privacy: .public), first at line \(found[0].line)")
        sourceTextView.setMarkers(found)
        // Keep the last lines scrollable above the banner.
        sourceScrollView.contentInsets.bottom = 64
        diagnosticBanner.show(found)
        mode = .source
        // Wait one run loop turn so the scroll view has its final size before scrolling.
        DispatchQueue.main.async { [weak self] in self?.revealMarker(at: 0) }
    }

    private func revealMarker(at index: Int) {
        guard markers.indices.contains(index),
              let lineRect = sourceTextView.lineRect(for: markers[index].lineRange) else { return }
        let clipView = sourceScrollView.contentView
        let topInset = sourceScrollView.contentInsets.top
        let visibleHeight = clipView.bounds.height - topInset
        // Place the line at ~40% of the area below the floating mode switch.
        let target = lineRect.midY - topInset - visibleHeight * 0.4
        let maxY = max(-topInset, sourceTextView.frame.height - clipView.bounds.height + sourceScrollView.contentInsets.bottom)
        clipView.scroll(to: NSPoint(x: 0, y: min(max(target, -topInset), maxY)))
        sourceScrollView.reflectScrolledClipView(clipView)
        sourceTextView.showFindIndicator(for: markers[index].range)
    }

    // MARK: Content helpers

    private nonisolated static func readSource(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    private func showRendered(_ content: NSView) {
        renderedContainer.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        renderedContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: renderedContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: renderedContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: renderedContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: renderedContainer.bottomAnchor),
        ])
    }

    private func makePDFView(_ document: PDFDocument) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        // Keep the first page clear of the floating mode switch.
        if let scrollView = pdfView.firstSubview(ofType: NSScrollView.self) {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: Self.toolbarInset, left: 0, bottom: 0, right: 0)
        }
        return pdfView
    }

    private static func progressView(tool: TypstTool) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Rendering with \(tool.kind.rawValue)…")
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private static func missingToolView() -> NSView {
        MessageView(
            symbol: "exclamationmark.triangle.fill",
            tint: .systemOrange,
            title: "Typst is not installed",
            message: "Rendering a preview requires either the Typst compiler or tinymist. "
                + "Install one of them with Homebrew, then open the preview again. "
                + "The highlighted source is still available via the Source button above.",
            commands: [
                .init(caption: "Install the Typst compiler (recommended)", command: "brew install typst"),
                .init(caption: "or install tinymist", command: "brew install tinymist"),
            ],
            footnote: "Homebrew itself can be installed from https://brew.sh. "
                + "Searched in: " + TypstToolchain.searchDirectories.map(\.path).joined(separator: ", "))
    }

    private static func errorView(title: String, message: String, details: String?) -> NSView {
        MessageView(symbol: "xmark.octagon.fill", tint: .systemRed,
                    title: title, message: message, details: details)
    }

    private static func view(for error: Error, file: URL) -> NSView {
        switch error {
        case TypstCompileError.failed(let tool, let status, let diagnostics):
            return errorView(
                title: "Could not render \(file.lastPathComponent)",
                message: "\(tool.kind.rawValue) exited with status \(status). The diagnostics are shown below.",
                details: diagnostics.isEmpty ? "No diagnostics were reported." : diagnostics)
        case TypstCompileError.timedOut(let tool):
            return errorView(
                title: "Rendering timed out",
                message: "\(tool.kind.rawValue) did not finish in time. Large documents or package downloads can take a while; try opening the preview again.",
                details: nil)
        case TypstCompileError.launchFailed(let tool, let underlying):
            return errorView(
                title: "Could not start \(tool.kind.rawValue)",
                message: "Launching \(tool.url.path) failed.",
                details: underlying.localizedDescription)
        default:
            return errorView(title: "Rendering failed", message: error.localizedDescription, details: nil)
        }
    }
}

/// Hands a freshly built, no longer mutated value from a background task to the main actor.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstSubview(ofType: type) { return match }
        }
        return nil
    }
}
