import SwiftUI

/// 「あなたは誰？」。初回起動と設定画面の両方で使う。
struct NameSelectView: View {
    var isOnboarding: Bool
    var onSelect: (String) -> Void

    @AppStorage(SenderName.key) private var currentName = ""
    @State private var customName = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmedCustom: String {
        customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("あなたは誰？")
                        .font(.largeTitle.bold())
                    Text("Echo で「〇〇から。」と名乗るときの名前です。\nあとから設定で変えられます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, isOnboarding ? 48 : 16)

                // 候補（ビルド時の FAM_ECHO_FAMILY）が空なら、ボタンは出さず自由入力だけにする
                if !SenderName.family.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(SenderName.family, id: \.self) { name in
                            Button {
                                choose(name)
                            } label: {
                                Text(name)
                                    .font(.title2.bold())
                                    .frame(maxWidth: .infinity, minHeight: 72)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(name == currentName ? .accentColor : .orange)
                            .accessibilityIdentifier("name-\(name)")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(SenderName.family.isEmpty ? "名前" : "ほかの名前")
                        .font(.headline)
                    HStack {
                        // Enter（IME の確定を含む）では決めない。「決定」ボタンだけで決める
                        TextField("名前を入力", text: $customName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .accessibilityIdentifier("custom-name-field")
                        Button("決定") { choose(trimmedCustom) }
                            .buttonStyle(.bordered)
                            .disabled(trimmedCustom.isEmpty || trimmedCustom.count > SenderName.maxLength)
                            .accessibilityIdentifier("custom-name-done")
                    }
                    if trimmedCustom.count > SenderName.maxLength {
                        Text("\(SenderName.maxLength)文字までです")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(isOnboarding ? "" : "名前")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ name: String) {
        guard !name.isEmpty else { return }
        currentName = name
        onSelect(name)
        if !isOnboarding { dismiss() }
    }
}
