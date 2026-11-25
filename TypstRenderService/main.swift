import Foundation

final class TypstRenderService: NSObject, TypstRenderServiceProtocol {
    func compile(toolPath: String, toolKind: String, inputPath: String,
                 reply: @escaping (Data?, Int32, String) -> Void) {
        let tool = TypstTool(kind: TypstTool.Kind(rawValue: toolKind) ?? .typst,
                             url: URL(fileURLWithPath: toolPath))
        do {
            let pdf = try TypstCompiler.compile(URL(fileURLWithPath: inputPath), using: tool)
            reply(pdf, TypstRenderStatus.success, "")
        } catch TypstCompileError.failed(_, let status, let diagnostics) {
            reply(nil, status == 0 ? 1 : status, diagnostics)
        } catch TypstCompileError.timedOut {
            reply(nil, TypstRenderStatus.timedOut, "")
        } catch TypstCompileError.launchFailed(_, let underlying) {
            reply(nil, TypstRenderStatus.launchFailed, underlying.localizedDescription)
        } catch {
            reply(nil, TypstRenderStatus.launchFailed, error.localizedDescription)
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TypstRenderServiceProtocol.self)
        connection.exportedObject = TypstRenderService()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
