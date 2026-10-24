import Foundation
import SwiftData

/// メイン画面に並ぶボタン（保存した文）。端末内だけに保存し、家族間では共有しない。
@Model
final class Preset {
    var label: String
    var text: String
    var order: Int
    var createdAt: Date

    init(label: String, text: String, order: Int, createdAt: Date = .now) {
        self.label = label
        self.text = text
        self.order = order
        self.createdAt = createdAt
    }

    static let defaults: [(label: String, text: String)] = [
        ("ご飯", "ご飯できたよ"),
        ("起床", "起きる時間だよ"),
    ]

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
        for (index, item) in defaults.enumerated() {
            context.insert(Preset(label: item.label, text: item.text, order: index))
        }
        try? context.save()
        if !inMemory { defaultsStore.set(true, forKey: seededKey) }
    }

    static func nextOrder(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Preset>(sortBy: [SortDescriptor(\.order, order: .reverse)])
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first?.order ?? -1) + 1
    }

    /// 履歴から保存するときのラベル案（先頭の数文字）
    static func suggestedLabel(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 8 ? trimmed : String(trimmed.prefix(8))
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
