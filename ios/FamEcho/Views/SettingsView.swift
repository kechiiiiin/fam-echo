import SwiftUI

struct SettingsView: View {
    @AppStorage(SenderName.key) private var senderName = ""
    @State private var healthResult: String?
    @State private var checking = false

    private let config = AppConfig.shared

    private var versionText: String {
        let info = Bundle.main
        let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version)（\($0)）" } ?? version
    }

    var body: some View {
        Form {
            Section("名前") {
                if let fixed = config.fixedName {
                    // 焼き込みビルド: 表示するだけ。変更の手段は出さない
                    LabeledContent("あなたの名前", value: fixed)
                        .accessibilityIdentifier("fixed-name")
                } else {
                    NavigationLink {
                        NameSelectView(isOnboarding: false) { _ in }
                    } label: {
                        LabeledContent("あなたの名前", value: senderName)
                    }
                    .accessibilityIdentifier("change-name")
                }
            }

            Section("ボタン") {
                NavigationLink("ボタンの並べ替え") {
                    PresetListView()
                }
                .accessibilityIdentifier("edit-presets")
            }

            Section {
                Button {
                    checkHealth()
                } label: {
                    HStack {
                        Text("Echo につながるか確かめる")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(config.baseURL == nil || checking)
                if let healthResult {
                    Text(healthResult)
                        .font(.footnote)
                        .accessibilityIdentifier("health-result")
                }
            }

            Section {
                Text("バージョン \(versionText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("app-version")
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
                    healthResult = "家の Mac には届きましたが、Echo の仕組み（Home Assistant）に届いていません"
                } else {
                    healthResult = "つながりました"
                }
            } catch {
                healthResult = "つながりません。家の Wi-Fi か通信を確かめてください"
            }
        }
    }
}
