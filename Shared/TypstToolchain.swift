import Foundation

/// A Typst-capable command line tool found on this machine.
struct TypstTool: Equatable {
    enum Kind: String {
        case typst
        case tinymist
    }

    let kind: Kind
    let url: URL

    /// Arguments that compile `input` to a PDF at `output`.
    /// (A file is used instead of stdout because `tinymist compile` ignores `-`.)
    func compileArguments(for input: URL, output: URL) -> [String] {
        ["compile", "--format", "pdf", input.path, output.path]
    }
}

enum TypstToolchain {
    /// The real home directory of the user. Inside the sandbox `NSHomeDirectory()`
    /// points to the container, so it is resolved through the password database.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Directories searched for the binaries. Quick Look extensions do not inherit
    /// the login shell's PATH, so the usual Homebrew and cargo locations are listed explicitly.
    static var searchDirectories: [URL] {
        let home = realHomeDirectory
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),   // Homebrew on Apple silicon
            URL(fileURLWithPath: "/usr/local/bin"),      // Homebrew on Intel
            home.appendingPathComponent(".cargo/bin"),
            home.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/opt/local/bin"),      // MacPorts
            URL(fileURLWithPath: "/usr/bin"),
        ]
    }

    /// Returns the preferred tool: `typst` first, then `tinymist`.
    static func locate() -> TypstTool? {
        let fm = FileManager.default
        for kind in [TypstTool.Kind.typst, .tinymist] {
            for dir in searchDirectories {
                let candidate = dir.appendingPathComponent(kind.rawValue)
                if fm.isExecutableFile(atPath: candidate.path) {
                    return TypstTool(kind: kind, url: candidate.resolvingSymlinksInPath())
                }
            }
        }
        return nil
    }
}

enum TypstCompileError: Error {
    case toolMissing
    case failed(tool: TypstTool, status: Int32, diagnostics: String)
    case timedOut(tool: TypstTool)
    case launchFailed(tool: TypstTool, underlying: Error)
}

enum TypstCompiler {
    /// Compiles the document to PDF data. Blocking; call from a background context.
    static func compile(_ input: URL, using tool: TypstTool, timeout: TimeInterval = 30) throws -> Data {
        let process = Process()
        process.executableURL = tool.url
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("typst-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        process.arguments = tool.compileArguments(for: input, output: output)
        process.currentDirectoryURL = input.deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        // Use the real home so Typst finds user fonts and the shared package cache
        // (~/Library/Caches/typst) instead of the sandbox container.
        env["HOME"] = TypstToolchain.realHomeDirectory.path
        env["NO_COLOR"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently to avoid blocking on full pipe buffers.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            throw TypstCompileError.launchFailed(tool: tool, underlying: error)
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TypstCompileError.timedOut(tool: tool)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let pdf = try? Data(contentsOf: output), !pdf.isEmpty else {
            let text = String(decoding: errData, as: UTF8.self)
            throw TypstCompileError.failed(tool: tool, status: process.terminationStatus, diagnostics: text)
        }
        return pdf
    }
}
