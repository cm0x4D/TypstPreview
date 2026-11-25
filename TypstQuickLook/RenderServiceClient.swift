import Foundation

/// Talks to the embedded TypstRenderService XPC service, which runs the compiler
/// (Quick Look extensions themselves may not launch processes).
enum RenderServiceClient {
    private static let lock = NSLock()
    private static var connection: NSXPCConnection?

    private static func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let new = NSXPCConnection(serviceName: TypstRenderStatus.serviceName)
        new.remoteObjectInterface = NSXPCInterface(with: TypstRenderServiceProtocol.self)
        new.invalidationHandler = {
            lock.lock()
            connection = nil
            lock.unlock()
        }
        new.resume()
        connection = new
        return new
    }

    static func invalidate() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    static func compile(_ input: URL, using tool: TypstTool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
                once.run { continuation.resume(throwing: TypstCompileError.launchFailed(tool: tool, underlying: error)) }
            }
            guard let service = proxy as? TypstRenderServiceProtocol else {
                once.run {
                    continuation.resume(throwing: TypstCompileError.launchFailed(
                        tool: tool, underlying: CocoaError(.featureUnsupported)))
                }
                return
            }
            service.compile(toolPath: tool.url.path, toolKind: tool.kind.rawValue, inputPath: input.path) { data, status, message in
                once.run {
                    if let data, status == TypstRenderStatus.success {
                        continuation.resume(returning: data)
                    } else if status == TypstRenderStatus.timedOut {
                        continuation.resume(throwing: TypstCompileError.timedOut(tool: tool))
                    } else if status == TypstRenderStatus.launchFailed {
                        continuation.resume(throwing: TypstCompileError.launchFailed(
                            tool: tool, underlying: NSError(domain: "TypstRenderService", code: Int(status),
                                                            userInfo: [NSLocalizedDescriptionKey: message])))
                    } else {
                        continuation.resume(throwing: TypstCompileError.failed(tool: tool, status: status, diagnostics: message))
                    }
                }
            }
        }
    }
}

/// Ensures a continuation is resumed exactly once (reply vs. connection error).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
