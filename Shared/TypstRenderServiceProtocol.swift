import Foundation

/// Quick Look extensions are not allowed to spawn processes, so compilation runs
/// in an XPC service embedded in the extension bundle.
@objc protocol TypstRenderServiceProtocol {
    /// Compiles `inputPath` with the tool at `toolPath`.
    /// Reply: PDF data on success, otherwise `nil` with a status code
    /// (`TypstRenderStatus` or the process exit status) and diagnostics text.
    func compile(toolPath: String, toolKind: String, inputPath: String,
                 reply: @escaping (Data?, Int32, String) -> Void)
}

enum TypstRenderStatus {
    static let success: Int32 = 0
    static let timedOut: Int32 = -2
    static let launchFailed: Int32 = -3

    /// The XPC service's bundle identifier: the extension's identifier + ".RenderService"
    /// (see PRODUCT_BUNDLE_IDENTIFIER in the project, driven by BUNDLE_ID_PREFIX).
    static var serviceName: String {
        (Bundle.main.bundleIdentifier ?? "com.example.TypstPreview.QuickLook") + ".RenderService"
    }
}
