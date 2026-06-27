import SwiftUI

// Left pane: the project description plus one section per group, mirroring
// the bare-`hammer` listing. Selecting a row drives the detail pane.
struct SidebarView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    List(selection: Binding(
      get: { model.selectedPath },
      set: { model.selectedPath = $0 }
    )) {
      if let desc = model.spec?.appDesc, !desc.isEmpty {
        Text(desc)
          .font(.headline)
          .padding(.vertical, 4)
      }
      ForEach(model.groups) { group in
        Section(header: Text(group.title)) {
          ForEach(group.tasks) { task in
            VStack(alignment: .leading, spacing: 1) {
              Text(task.path).font(.system(.body, design: .monospaced))
              if !task.brief.isEmpty {
                Text(task.brief).font(.caption).foregroundColor(.secondary).lineLimit(1)
              }
            }
            .tag(task.path)
          }
        }
      }
    }
    .listStyle(SidebarListStyle())
    .frame(minWidth: 220)
  }
}
