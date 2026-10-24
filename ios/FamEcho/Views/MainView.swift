import SwiftData
import SwiftUI

enum SendState: Equatable {
    case idle
    case sending(String)
    case success(String)
    case failure(String)
}

struct MainView: View {
    @AppStorage(SenderName.key) private var senderName = ""
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.order) private var presets: [Preset]

    @State private var draft = ""
    @State private var state: SendState = .idle
    @State private var clearTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

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
                        Image(systemName: "clock.arrow.circlepath")
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
        }
    }

    // MARK: - ボタンの並び

    private var presetGrid: some View {
        ScrollView {
            if presets.isEmpty {
                VStack(spacing: 8) {
                    Text("ボタンがありません")
                        .font(.headline)
                    Text("履歴から「ボタンに保存」するか、設定の「ボタンの編集」で足せます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(presets) { preset in
                        Button {
                            send(preset.text)
                        } label: {
                            VStack(spacing: 6) {
                                Text(preset.label)
                                    .font(.title2.bold())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Text(preset.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isSending || !config.isConfigured)
                        .accessibilityIdentifier("preset-\(preset.label)")
                    }
                }
                .padding()
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 入力欄

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if trimmedDraft.isEmpty {
                    Label("\(senderName)として送ります", systemImage: "person.fill")
                } else {
                    Text("「\(senderName)から。\(trimmedDraft)」と読み上げます")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityIdentifier("current-name")
            HStack(alignment: .bottom, spacing: 8) {
                // axis: .vertical の TextField は Return で改行するだけで、onSubmit も付けていない。
                // なので Enter（日本語 IME の変換確定を含む）で送信されることはない。送信は右のボタンだけ。
                TextField("読み上げる文", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .accessibilityIdentifier("composer")
                Button {
                    let text = trimmedDraft
                    send(text, clearsDraft: true)
                } label: {
                    Label("送信", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedDraft.isEmpty || trimmedDraft.count > 500 || isSending || !config.isConfigured)
                .accessibilityIdentifier("send-button")
            }
            if trimmedDraft.count > 500 {
                Text("500文字までです（いま\(trimmedDraft.count)文字）")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
