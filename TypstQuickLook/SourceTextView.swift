import AppKit

/// Text view for the highlighted source that can mark lines with compiler diagnostics:
/// a tinted full-width line background with an accent bar, plus an underlined span.
final class SourceTextView: NSTextView {
    private(set) var markers: [SourceMarker] = []

    /// Creates a read-only, TextKit 1 based text view inside a vertically scrolling scroll view.
    static func makeScrollable() -> (NSScrollView, SourceTextView) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = SourceTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    static func color(for severity: TypstDiagnostic.Severity) -> NSColor {
        severity == .error ? .systemRed : .systemOrange
    }

    func setMarkers(_ markers: [SourceMarker]) {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        for old in self.markers {
            storage.removeAttribute(.underlineStyle, range: old.range)
            storage.removeAttribute(.underlineColor, range: old.range)
            storage.removeAttribute(.backgroundColor, range: old.range)
            storage.removeAttribute(.toolTip, range: old.lineRange)
        }
        for marker in markers where NSMaxRange(marker.lineRange) <= storage.length {
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: Self.color(for: marker.severity),
                .backgroundColor: Self.color(for: marker.severity).withAlphaComponent(0.3),
            ], range: marker.range)
            storage.addAttribute(.toolTip, value: marker.message, range: marker.lineRange)
        }
        storage.endEditing()
        self.markers = markers
        needsDisplay = true
    }

    /// Rect of the given line range in view coordinates, spanning the full width.
    func lineRect(for lineRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        var rect = NSRect.null
        if lineRange.length == 0 || lineRange.location >= (textStorage?.length ?? 0) {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                rect = rect.union(fragment)
            }
        }
        guard !rect.isNull, !rect.isEmpty else { return nil }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = bounds.minX
        rect.size.width = bounds.width
        return rect
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for marker in markers {
            guard let line = lineRect(for: marker.lineRange), line.intersects(rect) else { continue }
            let color = Self.color(for: marker.severity)
            color.withAlphaComponent(0.14).setFill()
            line.fill()
            color.setFill()
            NSRect(x: line.minX, y: line.minY, width: 3, height: line.height).fill()
        }
    }
}
