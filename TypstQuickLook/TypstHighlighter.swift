import AppKit

/// A small hand-written scanner that understands Typst's three syntactic modes
/// (markup, code and math) well enough for syntax highlighting.
struct TypstHighlighter {
    enum Token {
        case comment, string, keyword, function, variable, number, constant, op
        case math, raw, heading, strong, emph, label, reference, escape, listMarker, link
    }

    struct Span {
        let range: NSRange
        let token: Token
    }

    // MARK: - Public API

    static func highlight(_ text: String, fontSize: CGFloat = 12) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ])

        // Very large files are shown without highlighting to keep the preview responsive.
        guard result.length < 1_500_000 else { return result }

        var scanner = TypstHighlighter(text)
        for span in scanner.scan() {
            apply(span, to: result, baseFont: font)
        }
        return result
    }

    // MARK: - Styling

    private static func apply(_ span: Span, to string: NSMutableAttributedString, baseFont: NSFont) {
        guard span.range.length > 0, NSMaxRange(span.range) <= string.length else { return }
        let fm = NSFontManager.shared
        switch span.token {
        case .strong:
            string.addAttribute(.font, value: fm.convert(baseFont, toHaveTrait: .boldFontMask), range: span.range)
        case .emph:
            string.addAttribute(.font, value: fm.convert(baseFont, toHaveTrait: .italicFontMask), range: span.range)
        case .heading:
            string.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold),
                .foregroundColor: NSColor.systemBlue,
            ], range: span.range)
        case .link:
            string.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: span.range)
        default:
            string.addAttribute(.foregroundColor, value: color(for: span.token), range: span.range)
        }
    }

    private static func color(for token: Token) -> NSColor {
        switch token {
        case .comment: return .systemGray
        case .string: return .systemGreen
        case .keyword: return .systemPink
        case .function: return .systemBlue
        case .variable: return .systemTeal
        case .number: return .systemOrange
        case .constant: return .systemOrange
        case .op: return .secondaryLabelColor
        case .math: return .systemPurple
        case .raw: return .systemBrown
        case .label, .reference: return .systemTeal
        case .escape: return .systemOrange
        case .listMarker: return .systemPink
        case .heading, .strong, .emph, .link: return .textColor
        }
    }

    // MARK: - Scanner

    private static let statementKeywords: Set<String> = [
        "let", "set", "show", "import", "include", "if", "else", "for", "while",
        "return", "context", "break", "continue", "in", "as", "not", "and", "or",
    ]
    private static let constants: Set<String> = ["none", "auto", "true", "false"]

    private let s: [unichar]
    private var i = 0
    private var spans: [Span] = []

    private init(_ text: String) {
        s = Array(text.utf16)
    }

    private mutating func scan() -> [Span] {
        markup(insideContentBlock: false)
        return spans
    }

    // Character helpers
    private var n: Int { s.count }
    private func ch(_ offset: Int = 0) -> unichar? {
        let j = i + offset
        return j >= 0 && j < n ? s[j] : nil
    }
    private static func u(_ c: Character) -> unichar { c.utf16.first! }
    private func isLetter(_ c: unichar?) -> Bool {
        guard let c, let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar) || c == Self.u("_")
    }
    private func isDigit(_ c: unichar?) -> Bool {
        guard let c else { return false }
        return c >= 48 && c <= 57
    }
    private func isAlnum(_ c: unichar?) -> Bool { isLetter(c) || isDigit(c) }
    private func isIdentChar(_ c: unichar?) -> Bool { isAlnum(c) || c == Self.u("-") }
    private func isSpace(_ c: unichar?) -> Bool { c == 32 || c == 9 }
    private func matches(_ literal: String) -> Bool {
        let chars = Array(literal.utf16)
        guard i + chars.count <= n else { return false }
        for (k, c) in chars.enumerated() where s[i + k] != c { return false }
        return true
    }

    private mutating func add(_ start: Int, _ end: Int, _ token: Token) {
        if end > start { spans.append(Span(range: NSRange(location: start, length: end - start), token: token)) }
    }

    private mutating func readIdentifier() -> String {
        let start = i
        while i < n, isIdentChar(s[i]) { i += 1 }
        // Identifiers cannot end with a hyphen ("a-" is "a" followed by a minus).
        while i > start + 1, s[i - 1] == Self.u("-") { i -= 1 }
        return String(utf16CodeUnits: Array(s[start..<i]), count: i - start)
    }

    // MARK: Shared constructs

    /// Handles comments, returns true if one was consumed.
    private mutating func comment() -> Bool {
        guard ch() == Self.u("/") else { return false }
        if ch(1) == Self.u("/") {
            let start = i
            while i < n, s[i] != 10 { i += 1 }
            add(start, i, .comment)
            return true
        }
        if ch(1) == Self.u("*") {
            let start = i
            var depth = 0
            while i < n {
                if matches("/*") { depth += 1; i += 2; continue }
                if matches("*/") { depth -= 1; i += 2; if depth == 0 { break }; continue }
                i += 1
            }
            add(start, i, .comment)
            return true
        }
        return false
    }

    private mutating func string() {
        let start = i
        i += 1
        while i < n {
            if s[i] == Self.u("\\") { i += 2; continue }
            if s[i] == Self.u("\"") { i += 1; break }
            i += 1
        }
        i = min(i, n)
        add(start, i, .string)
    }

    private mutating func raw() {
        let start = i
        var ticks = 0
        while ch() == Self.u("`") { ticks += 1; i += 1 }
        if ticks == 2 { add(start, i, .raw); return } // empty raw ``
        while i < n {
            if s[i] == Self.u("`") {
                var run = 0
                while ch() == Self.u("`") { run += 1; i += 1 }
                if run >= ticks { break }
                continue
            }
            if ticks == 1, s[i] == 10 { break }
            i += 1
        }
        add(start, i, .raw)
    }

    private mutating func math() {
        let start = i
        i += 1
        while i < n {
            if s[i] == Self.u("\\") { i += 2; continue }
            if s[i] == Self.u("\"") { string(); continue }
            if s[i] == Self.u("$") { i += 1; break }
            i += 1
        }
        i = min(i, n)
        add(start, i, .math)
    }

    private mutating func contentBlock() {
        let start = i
        i += 1 // [
        add(start, i, .op)
        markup(insideContentBlock: true)
        if ch() == Self.u("]") { add(i, i + 1, .op); i += 1 }
    }

    // MARK: Markup mode

    private mutating func markup(insideContentBlock: Bool) {
        var depth = 0
        var lineStart = true
        var strongStart: Int?
        var emphStart: Int?

        while i < n {
            let c = s[i]

            if c == 10 {
                // A blank line ends a paragraph and with it any open emphasis.
                if lineStart { strongStart = nil; emphStart = nil }
                lineStart = true
                i += 1
                continue
            }
            if insideContentBlock {
                if c == Self.u("[") { depth += 1 }
                if c == Self.u("]") {
                    if depth == 0 { return }
                    depth -= 1
                }
            }
            if comment() { continue }

            if lineStart {
                if isSpace(c) { i += 1; continue }
                lineStart = false
                if c == Self.u("=") {
                    let start = i
                    var end = i
                    while end < n, s[end] != 10 { end += 1 }
                    add(start, end, .heading)
                    while ch() == Self.u("=") { i += 1 }
                    continue
                }
                if (c == Self.u("-") || c == Self.u("+") || c == Self.u("/")) && (isSpace(ch(1)) || ch(1) == 10 || ch(1) == nil) {
                    add(i, i + 1, .listMarker)
                    i += 1
                    continue
                }
                if isDigit(c) {
                    var j = i
                    while j < n, isDigit(s[j]) { j += 1 }
                    if j < n, s[j] == Self.u("."), j + 1 < n, isSpace(s[j + 1]) {
                        add(i, j + 1, .listMarker)
                        i = j + 1
                        continue
                    }
                }
            }

            switch c {
            case Self.u("\\"):
                let start = i
                i += 1
                if matches("u{") {
                    while i < n, s[i] != Self.u("}") { i += 1 }
                    i = min(i + 1, n)
                } else if i < n, s[i] != 10 {
                    i += 1
                }
                add(start, i, .escape)
            case Self.u("`"):
                raw()
            case Self.u("$"):
                math()
            case Self.u("#"):
                hash()
            case Self.u("*"):
                if let start = strongStart {
                    add(start, i + 1, .strong)
                    strongStart = nil
                } else if !isAlnum(ch(-1)) {
                    strongStart = i
                }
                i += 1
            case Self.u("_"):
                if let start = emphStart {
                    add(start, i + 1, .emph)
                    emphStart = nil
                } else if !isAlnum(ch(-1)) {
                    emphStart = i
                }
                i += 1
            case Self.u("<"):
                var j = i + 1
                while j < n, isIdentChar(s[j]) || s[j] == Self.u(".") || s[j] == Self.u(":") { j += 1 }
                if j > i + 1, j < n, s[j] == Self.u(">") {
                    add(i, j + 1, .label)
                    i = j + 1
                } else {
                    i += 1
                }
            case Self.u("@") where isLetter(ch(1)):
                let start = i
                i += 1
                while i < n, isIdentChar(s[i]) || s[i] == Self.u(".") || s[i] == Self.u(":") { i += 1 }
                while i > start + 1, s[i - 1] == Self.u(".") || s[i - 1] == Self.u(":") { i -= 1 }
                add(start, i, .reference)
            case Self.u("h") where matches("https://") || matches("http://"):
                let start = i
                var parens = 0
                while i < n {
                    let d = s[i]
                    if d == 10 || isSpace(d) || d == Self.u("]") || d == Self.u(">") { break }
                    if d == Self.u("(") { parens += 1 }
                    if d == Self.u(")") { if parens == 0 { break }; parens -= 1 }
                    i += 1
                }
                while i > start, [Self.u("."), Self.u(","), Self.u(";"), Self.u(":"), Self.u("!"), Self.u("?")].contains(s[i - 1]) { i -= 1 }
                add(start, i, .link)
            case Self.u("~"):
                add(i, i + 1, .op)
                i += 1
            default:
                i += 1
            }
        }
    }

    // MARK: Code mode

    /// Handles an embedded code expression starting with `#` in markup.
    private mutating func hash() {
        let start = i
        let next = ch(1)
        if isLetter(next) {
            i += 1
            let name = readIdentifier()
            if Self.constants.contains(name) {
                add(start, i, .constant)
            } else if Self.statementKeywords.contains(name) {
                add(start, i, .keyword)
                code(until: nil, stopAtLineEnd: true)
            } else {
                let callee = ch() == Self.u("(") || ch() == Self.u("[")
                add(start, i, callee ? .function : .variable)
                postfix()
            }
        } else if next == Self.u("(") {
            add(start, start + 1, .op)
            i += 2
            code(until: Self.u(")"), stopAtLineEnd: false)
            postfix()
        } else if next == Self.u("{") {
            add(start, start + 1, .op)
            i += 2
            code(until: Self.u("}"), stopAtLineEnd: false)
        } else if next == Self.u("[") {
            add(start, start + 1, .op)
            i += 1
            contentBlock()
        } else if next == Self.u("\"") {
            add(start, start + 1, .op)
            i += 1
            string()
        } else {
            i += 1
        }
    }

    /// Calls, trailing content blocks and field accesses directly after an embedded expression.
    private mutating func postfix() {
        while i < n {
            if s[i] == Self.u("(") {
                i += 1
                code(until: Self.u(")"), stopAtLineEnd: false)
            } else if s[i] == Self.u("[") {
                contentBlock()
            } else if s[i] == Self.u("."), isLetter(ch(1)) {
                i += 1
                let start = i
                _ = readIdentifier()
                let callee = ch() == Self.u("(") || ch() == Self.u("[")
                add(start, i, callee ? .function : .variable)
            } else {
                break
            }
        }
    }

    private mutating func code(until close: unichar?, stopAtLineEnd: Bool) {
        while i < n {
            let c = s[i]
            if stopAtLineEnd, c == 10 { return }
            if stopAtLineEnd, c == Self.u(";") { i += 1; return }
            if let close, c == close { i += 1; return }
            if comment() { continue }

            switch c {
            case Self.u("\""):
                string()
            case Self.u("["):
                contentBlock()
            case Self.u("("):
                i += 1
                code(until: Self.u(")"), stopAtLineEnd: false)
            case Self.u("{"):
                i += 1
                code(until: Self.u("}"), stopAtLineEnd: false)
            case Self.u("$"):
                math()
            case Self.u(")"), Self.u("}"), Self.u("]"):
                // Unbalanced closer belonging to an outer construct.
                if stopAtLineEnd { return }
                i += 1
            case _ where isDigit(c) || (c == Self.u(".") && isDigit(ch(1)) && !isAlnum(ch(-1))):
                number()
            case _ where isLetter(c):
                let start = i
                let afterDot = ch(-1) == Self.u(".")
                let name = readIdentifier()
                if Self.constants.contains(name) {
                    add(start, i, .constant)
                } else if Self.statementKeywords.contains(name) && !afterDot {
                    add(start, i, .keyword)
                } else if ch() == Self.u("(") || ch() == Self.u("[") {
                    add(start, i, .function)
                }
            case Self.u("="), Self.u("+"), Self.u("-"), Self.u("*"), Self.u("/"),
                 Self.u("<"), Self.u(">"), Self.u("!"):
                add(i, i + 1, .op)
                i += 1
            default:
                i += 1
            }
        }
    }

    private mutating func number() {
        let start = i
        if matches("0x") || matches("0b") || matches("0o") {
            i += 2
            while i < n, isAlnum(s[i]) { i += 1 }
        } else {
            while i < n, isDigit(s[i]) || s[i] == Self.u(".") && isDigit(ch(1)) { i += 1 }
            if i < n, s[i] == Self.u("e"), isDigit(ch(1)) || (ch(1) == Self.u("-") && isDigit(ch(2))) {
                i += 2
                while i < n, isDigit(s[i]) { i += 1 }
            }
            // Units such as pt, mm, em, fr, deg and percentages.
            if i < n, s[i] == Self.u("%") {
                i += 1
            } else {
                while i < n, isLetter(s[i]) { i += 1 }
            }
        }
        add(start, i, .number)
    }
}
