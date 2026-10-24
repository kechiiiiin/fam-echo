import SwiftData
import SwiftUI

/// 送った文の履歴（新しい順）。行から「ボタンに保存」できる。
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SentEntry.sentAt, order: .reverse) private var entries: [SentEntry]

    @State private var saving: SentEntry?
    @State private var confirmClear = false
    @State private var savedNotice: String?

    var body: some View {
        List {
            if entries.isEmpty {
                Text("まだ送った文はありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .font(.body)
                        Text(entry.sentAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        saving = entry
                    } label: {
                        Label("ボタンに保存", systemImage: "plus.square.on.square")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("ボタンに保存")
                    .accessibilityIdentifier("save-as-preset-\(entry.text)")
                }
                .swipeActions(edge: .leading) {
                    Button {
                        saving = entry
                    } label: {
                        Label("ボタンに保存", systemImage: "plus.square.on.square")
                    }
                    .tint(.orange)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("履歴")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("すべて削除", role: .destructive) { confirmClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) {
                for entry in entries { context.delete(entry) }
                try? context.save()
            }
        }
        .sheet(item: $saving) { entry in
            PresetEditorView(title: "ボタンに保存", text: entry.text) { text in
                context.insert(Preset(text: text, order: Preset.nextOrder(in: context)))
                try? context.save()
                savedNotice = "「\(text)」をボタンに保存しました"
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let notice = savedNotice {
                Text(notice)
                    .font(.subheadline.bold())
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.green.opacity(0.2))
                    .accessibilityIdentifier("saved-notice")
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        savedNotice = nil
                    }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(entries[index])
        }
        try? context.save()
    }
}
