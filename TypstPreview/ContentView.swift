import SwiftUI

struct ContentView: View {
    @State private var tool: TypstTool? = TypstToolchain.locate()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Typst Preview").font(.title.bold())
                    Text("Quick Look extension for Typst (.typ) documents")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tool == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(tool == nil ? .orange : .green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 6) {
                        if let tool {
                            Text("Using \(tool.kind.rawValue)").font(.headline)
                            Text(tool.url.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        } else {
                            Text("Neither typst nor tinymist was found").font(.headline)
                            Text("Install one of them with Homebrew to enable the rendered preview:")
                            Text("brew install typst").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Text("brew install tinymist").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Check Again") { tool = TypstToolchain.locate() }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How to use").font(.headline)
                Text("1. Keep this app in your Applications folder and launch it once.")
                Text("2. Select a .typ file in Finder and press Space.")
                Text("3. Use the Preview / Source switch at the top to toggle between the rendered PDF and the highlighted source.")
                Text("If the preview does not appear, enable “Typst Preview” in System Settings › General › Login Items & Extensions › Quick Look.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}
