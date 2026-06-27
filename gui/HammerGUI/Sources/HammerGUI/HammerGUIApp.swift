import SwiftUI
import AppKit

// Launch parameters passed by `hammer --gui`:
//   --project <dir>   the Hammerfile's directory (cwd for all runs)
//   --hammer  <bin>   absolute path to the hammer binary to shell out to
struct LaunchConfig {
  var projectDir: String
  var hammerBin: String

  static func parse() -> LaunchConfig {
    var project = FileManager.default.currentDirectoryPath
    var hammer  = "hammer"
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--project": if i + 1 < args.count { project = args[i + 1]; i += 1 }
      case "--hammer":  if i + 1 < args.count { hammer  = args[i + 1]; i += 1 }
      default: break
      }
      i += 1
    }
    return LaunchConfig(projectDir: project, hammerBin: hammer)
  }
}

// Spawned directly (not via `open`), so force a regular foreground app and
// bring the window to front.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ note: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct HammerGUIApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model: AppModel

  init() {
    let cfg = LaunchConfig.parse()
    // Headless smoke test: load + decode the spec, print a summary, exit.
    // No window - verifies the hammer<->GUI data path in dev/CI.
    if CommandLine.arguments.contains("--selftest") {
      HammerGUIApp.selftest(cfg)
      exit(0)
    }
    _model = StateObject(wrappedValue: AppModel(config: cfg))
  }

  static func selftest(_ cfg: LaunchConfig) {
    let svc = HammerService(hammerBin: cfg.hammerBin, projectDir: cfg.projectDir)
    do {
      let spec = try svc.loadSpec()
      let groups = spec.commands.keys.sorted()
      let tasks = spec.commands.values.reduce(0) { $0 + $1.count }
      let msg = "selftest ok: program=\(spec.programName) groups=\(groups) tasks=\(tasks)\n"
      FileHandle.standardOutput.write(msg.data(using: .utf8)!)
    } catch {
      FileHandle.standardError.write("selftest FAILED: \(error)\n".data(using: .utf8)!)
      exit(1)
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { model.reload() }
    }
  }
}

struct ContentView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    HSplitView {
      SidebarView()
      VSplitView {
        detail
          .frame(minWidth: 480, minHeight: 280)
        OutputView()
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let task = model.selectedTask {
      TaskFormView(task: task).id(task.path)
    } else if let err = model.loadError {
      ScrollView {
        Text(err).font(.system(.body, design: .monospaced)).foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading).padding()
      }
    } else {
      Text("Select a task")
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
