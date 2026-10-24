import SwiftData
import SwiftUI

enum SendState: Equatable {
    case idle
    case sending(String)
    case success(String)
    case failure(String)
}

/// 「＋ 追加」と長押しの「編集」で開くシートの行き先
private enum EditorTarget: Identifiable {
    case add
    case edit(Preset)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let preset): "edit-\(preset.persistentModelID.hashValue)"
        }
    }
}

/// 削除した直後なら取り消せるよう、消した中身を覚えておく
private struct DeletedPreset {
    let text: String
    let order: Int
    let createdAt: Date
}

struct MainView: View {
    @AppStorage(SenderName.key) private var senderName = ""
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.order) private var presets: [Preset]

    @State private var draft = ""
    @State private var state: SendState = .idle
    @State private var clearTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool
    @State private var editor: EditorTarget?
    @State private var undoable: DeletedPreset?
    @State private var undoTask: Task<Void, Never>?

    private let client = SpeakClient()
    private let config = AppConfig.shared

    private var isSending: Bool {
        if case .sending = state { return true }
        return false
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let missing = config.missingDescription {
                    ConfigMissingBanner(message: missing)
                }
                presetGrid
                StatusBar(state: state)
                composer
            }
            .navigationTitle("fam-echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        // Label だとツールバーでアイコンだけに縮むので、アイコンと文字を並べて自前で組む
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("履歴")
                        }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                    .accessibilityLabel("履歴")
                    .accessibilityIdentifier("open-history")
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("設定")
                    .accessibilityIdentifier("open-settings")
                }
            }
            .sheet(item: $editor) { target in
                switch target {
                case .add:
                    PresetEditorView(title: "ボタンを追加", text: "") { text in
                        context.insert(Preset(text: text, order: Preset.nextOrder(in: context)))
                        try? context.save()
                    }
                case .edit(let preset):
                    PresetEditorView(title: "ボタンを編集", text: preset.text) { text in
                        preset.text = text
                        try? context.save()
                    }
                }
            }
        }
    }

    // MARK: - ボタンの並び

    private var presetGrid: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        send(preset.text)
                    } label: {
                        Text(preset.text)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange))
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .opacity(isSending || !config.isConfigured ? 0.5 : 1)
                    .accessibilityIdentifier("preset-\(preset.text)")
                    .contextMenu {
                        Button {
                            editor = .edit(preset)
                        } label: {
                            Label("編集", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            delete(preset)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    editor = .add
                } label: {
                    Label("追加", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("add-preset-button")
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            if undoable != nil {
                HStack {
                    Text("ボタンを削除しました")
                    Spacer()
                    Button("元に戻す") { undoDelete() }
                        .bold()
                        .accessibilityIdentifier("undo-delete")
                }
                .font(.subheadline)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: undoable != nil)
    }

    private func delete(_ preset: Preset) {
        undoTask?.cancel()
        undoable = DeletedPreset(text: preset.text, order: preset.order, createdAt: preset.createdAt)
        context.delete(preset)
        try? context.save()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { undoable = nil }
        }
    }

    private func undoDelete() {
        guard let item = undoable else { return }
        undoTask?.cancel()
        context.insert(Preset(text: item.text, order: item.order, createdAt: item.createdAt))
        try? context.save()
        undoable = nil
    }

    // MARK: - 入力欄

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(senderName)として送ります", systemImage: "person.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("current-name")
            // TextEditor は Return で改行するだけで、送信には結びつけていない。
            // なので Enter（日本語 IME の変換確定を含む）で送信されることはない。送信は下のボタンだけ。
            TextEditor(text: $draft)
                .focused($composerFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 100, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("読み上げる文")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("composer")
            if trimmedDraft.count > 500 {
                Text("500文字までです（いま\(trimmedDraft.count)文字）")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                let text = trimmedDraft
                send(text, clearsDraft: true)
            } label: {
                Label("送信", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedDraft.isEmpty || trimmedDraft.count > 500 || isSending || !config.isConfigured)
            .accessibilityIdentifier("send-button")
        }
        .padding()
        .background(.bar)
    }

    // MARK: - 送信

    private func send(_ text: String, clearsDraft: Bool = false) {
        guard !text.isEmpty, !isSending else { return }
        clearTask?.cancel()
        state = .sending(text)
        let sender = senderName
        Task {
            do {
                _ = try await client.speak(from: sender, text: text)
                context.insert(SentEntry(text: text, sender: sender))
                try? context.save()
                if clearsDraft {
                    draft = ""
                    composerFocused = false
                }
                state = .success(text)
                scheduleClear()
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    private func scheduleClear() {
        clearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, case .success = state { state = .idle }
        }
    }
}

/// 押している間だけ少し沈む（色や形は呼び出し側が決める）
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct ConfigMissingBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(message).bold()
                Text("ios/Secrets.xcconfig を用意してビルドし直してください")
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.3))
        .accessibilityIdentifier("config-missing")
    }
}

private struct StatusBar: View {
    let state: SendState

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .sending:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("送信中…")
                }
                .foregroundStyle(.secondary)
            case .success(let text):
                Label("届きました: \(text)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let reason):
                Label("送れませんでした: \(reason)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline.bold())
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, state == .idle ? 0 : 8)
        .accessibilityIdentifier("send-status")
        .animation(.default, value: state)
    }
}
