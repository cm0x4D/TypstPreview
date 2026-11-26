import Foundation

/// A compiler diagnostic parsed from typst/tinymist's human-readable output:
///
///     error: unknown variable: nope
///       ┌─ main.typ:3:5
///       │
///     3 │ Hello #nope
///       │        ^^^^
///
///       while including `inc.typ` at main.typ:1:1        (typst)
///     help: while including `inc.typ`                    (tinymist, followed by its own ┌─ line)
struct TypstDiagnostic: Equatable {
    enum Severity: String {
        case error, warning
    }

    struct Location: Equatable {
        let path: String
        /// 1-based line number.
        let line: Int
        /// 0-based column in Unicode scalars (that's what Typst prints, despite the 1-based line).
        let column: Int
        /// Number of `^` markers below the snippet, if any.
        var length: Int = 0
    }

    let severity: Severity
    var message: String
    /// The primary location first, followed by the trace ("while including/calling …").
    var locations: [Location] = []
}

/// A diagnostic resolved to a position in the previewed file's text.
struct SourceMarker {
    let severity: TypstDiagnostic.Severity
    let message: String
    /// 1-based line in the previewed file.
    let line: Int
    /// Full line, including the line break (UTF-16, for NSString/NSTextView).
    let lineRange: NSRange
    /// The span the diagnostic points at (at least one character, clamped to the line).
    let range: NSRange
}

enum TypstDiagnostics {
    // MARK: Parsing

    static func parse(_ output: String) -> [TypstDiagnostic] {
        var result: [TypstDiagnostic] = []
        var current: TypstDiagnostic?
        var awaitingTraceLocation = false
        var lastLocationTakesCarets = false

        func flush() {
            if let current { result.append(current) }
            current = nil
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let match = rawLine.firstMatch(of: #/^(error|warning): (.*)$/#) {
                flush()
                current = TypstDiagnostic(severity: match.1 == "error" ? .error : .warning,
                                          message: String(match.2))
                awaitingTraceLocation = false
                lastLocationTakesCarets = false
                continue
            }
            guard current != nil else { continue }

            if let match = line.firstMatch(of: #/^┌─ (.+):(\d+):(\d+)$/#) {
                // Primary location, or the location of a tinymist "help: while …" trace entry.
                if current!.locations.isEmpty || awaitingTraceLocation {
                    current!.locations.append(.init(path: String(match.1), line: Int(match.2) ?? 1,
                                                    column: Int(match.3) ?? 0))
                    lastLocationTakesCarets = true
                }
                awaitingTraceLocation = false
            } else if lastLocationTakesCarets, let match = line.firstMatch(of: #/^│\s*(\^+)/#) {
                current!.locations[current!.locations.count - 1].length = match.1.count
                lastLocationTakesCarets = false
            } else if line.hasPrefix("help: while ") || line.hasPrefix("help: error occurred while ") {
                awaitingTraceLocation = true
            } else if let match = line.firstMatch(of: #/^(?:help: )?(?:error occurred )?while .* at (.+):(\d+):(\d+)$/#) {
                // typst: "while including `inc.typ` at main.typ:1:1"
                current!.locations.append(.init(path: String(match.1), line: Int(match.2) ?? 1,
                                                column: Int(match.3) ?? 0))
                lastLocationTakesCarets = false
            } else if line.hasPrefix("hint: ") {
                current!.message += " (\(line))"
            }
        }
        flush()
        return result
    }

    // MARK: Mapping to the previewed file

    /// Resolves diagnostics to ranges in `text`, the contents of `file`.
    /// Diagnostics in other files are mapped to the trace entry in `file` (e.g. the `#include`).
    static func markers(for diagnostics: [TypstDiagnostic], in text: String, file: URL) -> [SourceMarker] {
        let lines = LineIndex(text)
        var markers: [SourceMarker] = []
        var seenLines = Set<Int>()

        // Errors first, so that an error wins when an error and a warning share a line.
        let ordered = diagnostics.filter { $0.severity == .error } + diagnostics.filter { $0.severity == .warning }
        for diagnostic in ordered {
            guard let index = diagnostic.locations.firstIndex(where: { refersTo(file, path: $0.path) }) else { continue }
            let location = diagnostic.locations[index]
            guard let lineRange = lines.range(ofLine: location.line) else { continue }

            var message = "\(diagnostic.severity.rawValue): \(diagnostic.message)"
            if index > 0, let primary = diagnostic.locations.first {
                message += " — in \((primary.path as NSString).lastPathComponent):\(primary.line)"
            }

            // typst's trace entries ("while including … at main.typ:2:1") carry no span: mark the rest of the line.
            let length = location.length > 0 ? location.length : (index > 0 ? Int.max / 2 : 1)
            let range = lines.span(line: location.line, column: location.column, length: length, in: text)
            // One marker per line.
            guard !seenLines.contains(location.line) else { continue }
            seenLines.insert(location.line)
            markers.append(SourceMarker(severity: diagnostic.severity, message: message,
                                        line: location.line, lineRange: lineRange, range: range))
        }
        return markers.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            return $0.line < $1.line
        }
    }

    private static func refersTo(_ file: URL, path: String) -> Bool {
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            // typst prints paths relative to the project root (the file's directory).
            candidate = file.deletingLastPathComponent().appendingPathComponent(path)
        }
        let a = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let b = file.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b
    }
}

/// UTF-16 offsets of line starts, for converting line/column pairs to NSRanges.
private struct LineIndex {
    private let starts: [Int]
    private let length: Int

    init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        self.starts = starts
        self.length = offset
    }

    func range(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= starts.count else { return nil }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] : length
        return NSRange(location: start, length: end - start)
    }

    /// Converts a scalar column + length on `line` into a UTF-16 range, clamped to the line.
    func span(line: Int, column: Int, length: Int, in text: String) -> NSRange {
        guard let lineRange = range(ofLine: line) else { return NSRange(location: 0, length: 0) }
        let ns = text as NSString
        var content = ns.substring(with: lineRange)
        if content.hasSuffix("\n") { content.removeLast() }
        if content.hasSuffix("\r") { content.removeLast() }

        let scalars = Array(content.unicodeScalars)
        let startScalar = min(max(column, 0), scalars.count)
        let endScalar = min(startScalar + length, scalars.count)
        let utf16Start = scalars[..<startScalar].reduce(0) { $0 + UTF16.width($1) }
        var utf16Length = scalars[startScalar..<endScalar].reduce(0) { $0 + UTF16.width($1) }

        let span = scalars[startScalar..<endScalar]
        if span.allSatisfy({ $0.properties.isWhitespace }) {
            // Errors at the end of a line ("expected expression") point at nothing visible:
            // mark the last non-whitespace character before the position instead.
            if let last = scalars[..<startScalar].lastIndex(where: { !$0.properties.isWhitespace }) {
                let offset = scalars[..<last].reduce(0) { $0 + UTF16.width($1) }
                return NSRange(location: lineRange.location + offset, length: UTF16.width(scalars[last]))
            }
            utf16Length = max(utf16Length, 0)
        }
        return NSRange(location: lineRange.location + utf16Start, length: utf16Length)
    }
}
