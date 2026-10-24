import SwiftData
import SwiftUI

/// ボタンの並べ替えが主。タップで編集、左スワイプで削除もできる（追加はメイン画面）。
struct PresetListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.order) private var presets: [Preset]

    @State private var editing: Preset?

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
                Text("右上の「編集」を押すと、右端の ≡ をドラッグして並べ替えられます。文を直すときは行をタップ、消すときは左へスワイプ")
            }
        }
        .navigationTitle("ボタンの並べ替え")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editing) { preset in
            PresetEditorView(title: "ボタンを編集", text: preset.text) { text in
                preset.text = text
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
