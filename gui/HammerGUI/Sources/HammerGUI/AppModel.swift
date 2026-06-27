import Foundation
import Combine

// Single source of UI state. Holds the decoded spec, the current
// selection, and the live output of the last/active run.
final class AppModel: ObservableObject {
  let config: LaunchConfig

  @Published var spec: Spec?
  @Published var loadError: String?
  @Published var selectedPath: String?
  @Published var output: String = ""
  @Published var lastCommand: String = ""
  @Published var running = false
  @Published var lastExit: Int32?

  private let service: HammerService

  init(config: LaunchConfig) {
    self.config = config
    self.service = HammerService(hammerBin: config.hammerBin, projectDir: config.projectDir)
  }

  struct Group: Identifiable {
    let id: String
    let title: String
    let tasks: [TaskDef]
  }

  // Mirror the bare-`hammer` listing: "__root" group first (labeled
  // "Commands"), then groups alphabetically; tasks by [depth, name].
  // JSON object key order isn't preserved on decode, so sort here.
  var groups: [Group] {
    guard let spec = spec else { return [] }
    let keys = spec.commands.keys.sorted { a, b in
      if a == "__root" { return b != "__root" }
      if b == "__root" { return false }
      return a < b
    }
    return keys.map { key in
      let tasks = (spec.commands[key] ?? [:]).values.sorted { lhs, rhs in
        let da = lhs.path.filter { $0 == ":" }.count
        let db = rhs.path.filter { $0 == ":" }.count
        return da != db ? da < db : lhs.path < rhs.path
      }
      return Group(id: key, title: key == "__root" ? "Commands" : key, tasks: tasks)
    }
  }

  var selectedTask: TaskDef? {
    guard let path = selectedPath, let spec = spec else { return nil }
    for tasks in spec.commands.values {
      if let t = tasks[path] { return t }
    }
    return nil
  }

  func reload() {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let s = try self.service.loadSpec()
        DispatchQueue.main.async {
          self.spec = s
          self.loadError = nil
          if self.selectedPath == nil || self.selectedTask == nil {
            self.selectedPath = self.groups.first?.tasks.first?.path
          }
        }
      } catch {
        DispatchQueue.main.async { self.loadError = "failed to load tasks:\n\(error)" }
      }
    }
  }

  func run(argv: [String], display: String) {
    guard !running else { return }
    output = ""
    lastExit = nil
    lastCommand = display
    running = true
    service.runTask(argv,
      onLine: { chunk in DispatchQueue.main.async { self.output += chunk } },
      onExit: { code in DispatchQueue.main.async { self.running = false; self.lastExit = code } })
  }
}
