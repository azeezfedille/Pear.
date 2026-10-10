import SwiftUI

struct MDBListPicker: View {
    @AppStorage("mdblist.lists") private var selected = ""
    @State private var lists: [MDBListClient.UserList] = []
    @State private var loading = true

    private var ids: Set<Int> { Set(selected.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        List(lists) { l in
            Toggle(isOn: Binding(get: { ids.contains(l.id) }, set: { toggle(l.id, $0) })) {
                VStack(alignment: .leading) {
                    Text(l.name)
                    if let n = l.items { Text("\(n) titles").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .overlay {
            if loading { ProgressView() }
            else if lists.isEmpty {
                ContentUnavailableView("No lists found", systemImage: "list.bullet",
                    description: Text("Check your MDBList API key, or create a list on mdblist.com."))
            }
        }
        .navigationTitle("Show on Home")
        .task { lists = await MDBListClient.shared.userLists(); loading = false }
    }

    private func toggle(_ id: Int, _ on: Bool) {
        var s = ids
        if on { s.insert(id) } else { s.remove(id) }
        selected = s.sorted().map(String.init).joined(separator: ",")
    }
}
