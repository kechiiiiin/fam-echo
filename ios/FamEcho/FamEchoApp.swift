import SwiftData
import SwiftUI

@main
struct FamEchoApp: App {
    let container: ModelContainer
    static let isUITestReset = ProcessInfo.processInfo.arguments.contains("--uitest-reset")

    init() {
        // UI テスト用: --uitest-reset で名前・ボタン・履歴をまっさらにし、保存先もメモリだけにする
        let resetForUITest = Self.isUITestReset
        if resetForUITest, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.removeObject(forKey: SenderName.key)
        }
        // 名前を焼き込んだビルドは、以前に選んで残っている名前より焼き込みを優先する（名前の順番: 焼き込み → 保存済み → 名前選び）
        if let fixed = AppConfig.shared.fixedName {
            UserDefaults.standard.set(fixed, forKey: SenderName.key)
        }
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: resetForUITest)
            container = try ModelContainer(for: Preset.self, SentEntry.self, configurations: config)
        } catch {
            fatalError("SwiftData の保存先を開けません: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

/// 名前が未設定なら「あなたは誰？」、設定済みならメイン画面。焼き込みがあれば最初からメイン画面。
struct RootView: View {
    @AppStorage(SenderName.key) private var senderName = AppConfig.shared.fixedName ?? ""
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if AppConfig.shared.fixedName == nil && senderName.isEmpty {
                NameSelectView(isOnboarding: true) { senderName = $0 }
            } else {
                MainView()
            }
        }
        .task { Preset.seedDefaultsIfNeeded(in: context, inMemory: FamEchoApp.isUITestReset) }
    }
}

enum SenderName {
    static let key = "senderName"
    /// 名前選択の候補はソースに書かない。ビルド時の FAM_ECHO_FAMILY（Secrets.xcconfig）から読む
    static var family: [String] { AppConfig.shared.family }
    static let maxLength = 20
}
