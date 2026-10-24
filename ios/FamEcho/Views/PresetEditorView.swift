import SwiftUI

/// ボタン1つの文を編集する（追加・編集・履歴からの保存で共通）。入力欄は「読み上げる文」だけ。
struct PresetEditorView: View {
    let title: String
    @State var text: String
    var onSave: (String) -> Void

    @AppStorage(SenderName.key) private var senderName = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedText.isEmpty && trimmedText.count <= 500 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // axis: .vertical の TextField は Return で改行するだけ。Enter（IME の確定を含む）で保存はしない
                    TextField("例: ご飯できたよ", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                        .accessibilityIdentifier("editor-text")
                } header: {
                    Text("読み上げる文")
                } footer: {
                    Text("Echo では「\(senderName)から。\(trimmedText)」")
                        .accessibilityIdentifier("editor-preview")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(trimmedText)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("editor-save")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
