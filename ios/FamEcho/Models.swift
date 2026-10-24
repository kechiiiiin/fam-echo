import Foundation
import SwiftData

/// メイン画面に並ぶボタン（保存した文）。端末内だけに保存し、家族間では共有しない。
/// ボタンには文（text）だけを出す。`label` は旧版（ボタン名＋文の2段表示）の名残で、いまは使わない。
/// SwiftData の保存済みデータを壊さず読み続けるため、プロパティ自体は残している（消すとスキーマ変更になる）。
@Model
final class Preset {
    var label: String
    var text: String
    var order: Int
    var createdAt: Date

    init(text: String, order: Int, createdAt: Date = .now) {
        self.label = ""
        self.text = text
        self.order = order
        self.createdAt = createdAt
    }

    static let defaults: [String] = ["ご飯できたよ", "起きる時間だよ"]

    private static let seededKey = "didSeedDefaultPresets"

    /// 初回だけ初期ボタンを入れる。消したあとに復活させないよう、入れたこと自体を覚えておく。
    /// UI テスト（保存先がメモリだけ）のときは毎回入れ、印は残さない（本来の保存先に入れ損ねないように）。
    static func seedDefaultsIfNeeded(in context: ModelContext, inMemory: Bool = false) {
        let defaultsStore = UserDefaults.standard
        if inMemory {
            guard (try? context.fetchCount(FetchDescriptor<Preset>())) == 0 else { return }
        } else {
            guard !defaultsStore.bool(forKey: seededKey) else { return }
        }
        for (index, text) in defaults.enumerated() {
            context.insert(Preset(text: text, order: index))
        }
        try? context.save()
        if !inMemory { defaultsStore.set(true, forKey: seededKey) }
    }

    static func nextOrder(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.order, order: .reverse)])
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first?.order ?? -1) + 1
    }
}

/// 送った文の履歴（送れたものだけ）。
@Model
final class SentEntry {
    var text: String
    var sender: String
    var sentAt: Date

    init(text: String, sender: String, sentAt: Date = .now) {
        self.text = text
        self.sender = sender
        self.sentAt = sentAt
    }
}
