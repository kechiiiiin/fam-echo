import SwiftUI

struct SettingsView: View {
    @AppStorage(SenderName.key) private var senderName = ""
    @State private var healthResult: String?
    @State private var checking = false

    private let config = AppConfig.shared

    var body: some View {
        Form {
            Section("名前") {
                NavigationLink {
                    NameSelectView(isOnboarding: false) { _ in }
                } label: {
                    LabeledContent("あなたの名前", value: senderName)
                }
                .accessibilityIdentifier("change-name")
            }

            Section("ボタン") {
                NavigationLink("ボタンの編集・並べ替え") {
                    PresetListView()
                }
                .accessibilityIdentifier("edit-presets")
            }

            Section {
                LabeledContent("送信先", value: config.baseURL?.host ?? "未設定")
                LabeledContent("トークン", value: config.token.isEmpty ? "未設定" : "設定済み")
                Button {
                    checkHealth()
                } label: {
                    HStack {
                        Text("つながるか確かめる")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(config.baseURL == nil || checking)
                if let healthResult {
                    Text(healthResult)
                        .font(.footnote)
                        .accessibilityIdentifier("health-result")
                }
            } header: {
                Text("送信先")
            } footer: {
                Text("送信先とトークンはビルド時に埋め込まれます（ios/Secrets.xcconfig）")
            }

            Section {
                Text("ボタンと履歴はこの iPhone の中だけに保存され、家族とは共有されません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
            }
        }
        .navigationTitle("設定")
    }

    private func checkHealth() {
        checking = true
        healthResult = nil
        Task {
            defer { checking = false }
            do {
                let health = try await SpeakClient().health()
                if let ha = health.ha, !ha.reachable {
                    healthResult = "窓口には届きました。Home Assistant には届いていません"
                } else {
                    healthResult = "窓口にも Home Assistant にも届きました"
                }
            } catch {
                healthResult = "届きません: \(error.localizedDescription)"
            }
        }
    }
}
