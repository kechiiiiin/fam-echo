import SwiftData
import SwiftUI

/// ボタンの編集・削除・並べ替え・追加。初期のボタンも同じ扱い。
struct PresetListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.order) private var presets: [Preset]

    @State private var editing: Preset?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(presets) { preset in
                    Button {
                        editing = preset
                    } label: {
                        Text(preset.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("preset-row-\(preset.text)")
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            } footer: {
                Text("行をタップで編集、左へスワイプで削除、「編集」で並べ替え")
            }
        }
        .navigationTitle("ボタンの編集")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("ボタンを追加")
                .accessibilityIdentifier("add-preset")
            }
        }
        .sheet(item: $editing) { preset in
            PresetEditorView(title: "ボタンを編集", text: preset.text) { text in
                preset.text = text
                try? context.save()
            }
        }
        .sheet(isPresented: $adding) {
            PresetEditorView(title: "ボタンを追加", text: "") { text in
                context.insert(Preset(text: text, order: Preset.nextOrder(in: context)))
                try? context.save()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(presets[index])
        }
        try? context.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = presets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, preset) in reordered.enumerated() where preset.order != index {
            preset.order = index
        }
        try? context.save()
    }
}
