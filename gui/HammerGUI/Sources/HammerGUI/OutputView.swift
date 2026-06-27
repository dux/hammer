import SwiftUI
import AppKit

// Bottom pane: the invoked command line, the streamed stdout/stderr, and
// a colored exit banner. Auto-scrolls to the tail as output arrives.
struct OutputView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !model.lastCommand.isEmpty {
        Text("> \(model.lastCommand)")
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 8).padding(.top, 6)
      }
      ScrollViewReader { proxy in
        ScrollView {
          Text(model.output.isEmpty ? "no output yet" : model.output)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(model.output.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .id("tail")
        }
        .onChange(of: model.output) { _ in
          withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
        }
      }
      if let exit = model.lastExit {
        Text(exit == 0 ? "exit 0" : "exit \(exit)")
          .font(.caption).bold()
          .foregroundColor(exit == 0 ? .green : .red)
          .padding(.horizontal, 8).padding(.bottom, 6)
      }
    }
    .frame(minHeight: 140)
    .background(Color(NSColor.textBackgroundColor))
  }
}
