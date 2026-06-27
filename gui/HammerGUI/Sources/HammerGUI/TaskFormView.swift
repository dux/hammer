import SwiftUI

// Detail pane: a form built from the selected task's options, plus a
// trailing positional-args field and the Run button. Field state is local
// and re-seeded whenever the task changes (parent uses `.id(task.path)`).
struct TaskFormView: View {
  let task: TaskDef
  @EnvironmentObject var model: AppModel

  @State private var text: [String: String] = [:]
  @State private var bools: [String: Bool] = [:]
  @State private var extraArgs: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(task.options) { opt in field(opt) }
          argsField
        }
        .padding()
      }
      Divider()
      footer
    }
    .onAppear(perform: seed)
  }

  // MARK: pieces

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(task.path).font(.system(.title2, design: .monospaced))
      if !task.desc.isEmpty {
        Text(task.desc).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 14) {
        if !task.alts.isEmpty {
          Text("alias: \(task.alts.joined(separator: ", "))").font(.caption).foregroundColor(.secondary)
        }
        if !task.needs.isEmpty {
          Text("runs first: \(task.needs.joined(separator: ", "))").font(.caption).foregroundColor(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }

  @ViewBuilder private func field(_ opt: OptionDef) -> some View {
    if opt.type == "boolean" {
      Toggle(isOn: binding(bool: opt.name)) { label(opt) }
    } else {
      VStack(alignment: .leading, spacing: 3) {
        label(opt)
        TextField(opt.placeholder ?? opt.name, text: binding(text: opt.name))
          .textFieldStyle(RoundedBorderTextFieldStyle())
        if let d = opt.desc, !d.isEmpty {
          Text(d).font(.caption).foregroundColor(.secondary)
        }
      }
    }
  }

  private func label(_ opt: OptionDef) -> some View {
    HStack(spacing: 5) {
      Text(opt.name).font(.system(.body, design: .monospaced))
      if opt.required { Text("*").foregroundColor(.red) }
      if !opt.aliases.isEmpty {
        Text("(\(opt.aliases.joined(separator: ", ")))").font(.caption).foregroundColor(.secondary)
      }
    }
  }

  private var argsField: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("arguments").font(.system(.body, design: .monospaced))
      TextField("extra positional args", text: $extraArgs)
        .textFieldStyle(RoundedBorderTextFieldStyle())
      Text("space-separated positionals, appended after the flags")
        .font(.caption).foregroundColor(.secondary)
    }
  }

  private var footer: some View {
    HStack {
      if !model.running, let exit = model.lastExit {
        Text(exit == 0 ? "done" : "exit \(exit)")
          .font(.caption).foregroundColor(exit == 0 ? .green : .red)
      }
      Spacer()
      Button(action: runTask) {
        Text(model.running ? "Running…" : "Run").frame(minWidth: 60)
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.running || !requiredFilled)
    }
    .padding()
  }

  // MARK: bindings + state

  private func binding(text name: String) -> Binding<String> {
    Binding(get: { text[name] ?? "" }, set: { text[name] = $0 })
  }
  private func binding(bool name: String) -> Binding<Bool> {
    Binding(get: { bools[name] ?? false }, set: { bools[name] = $0 })
  }

  private func seed() {
    var t: [String: String] = [:]
    var b: [String: Bool] = [:]
    for o in task.options {
      if o.type == "boolean" { b[o.name] = o.default?.boolValue ?? false }
      else { t[o.name] = o.default?.formText ?? "" }
    }
    text = t; bools = b; extraArgs = ""
  }

  private var requiredFilled: Bool {
    task.options.allSatisfy { o in
      guard o.required, o.type != "boolean" else { return true }
      return !(text[o.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
  }

  // MARK: run

  private func runTask() {
    var argv = [task.path]
    for o in task.options {
      let flag = o.name.replacingOccurrences(of: "_", with: "-")
      if o.type == "boolean" {
        let on = bools[o.name] ?? false
        let def = o.default?.boolValue ?? false
        if on && !def { argv.append("--\(flag)") }
        else if !on && def { argv.append("--no-\(flag)") }
      } else {
        let v = (text[o.name] ?? "").trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { argv.append("--\(flag)=\(v)") }
      }
    }
    argv.append(contentsOf: extraArgs.split(separator: " ").map(String.init))
    let prog = model.spec?.programName ?? "hammer"
    model.run(argv: argv, display: "\(prog) \(argv.joined(separator: " "))")
  }
}
