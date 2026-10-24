import SwiftUI

/// ボタン1つのラベルと本文を編集する（新規・編集・履歴からの保存で共通）。
struct PresetEditorView: View {
    let title: String
    @State var label: String
    @State var text: String
    var onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedLabel.isEmpty && !trimmedText.isEmpty && trimmedText.count <= 500 && trimmedLabel.count <= 20
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例: ご飯", text: $label)
                        .accessibilityIdentifier("editor-label")
                } header: {
                    Text("ラベル（ボタンに出る文字）")
                }
                Section {
                    TextField("例: ご飯できたよ", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("editor-text")
                } header: {
                    Text("読み上げる文")
                } footer: {
                    Text("Echo では「名前から。」が前に付きます")
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
                        onSave(trimmedLabel, trimmedText)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("editor-save")
                }
            }
        }
    }
}
