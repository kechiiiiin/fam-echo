import Foundation

/// ビルド時に Config.xcconfig →（#include?）Secrets.xcconfig → Info.plist で埋め込まれた設定。
/// 送信先・トークン・名前選択の候補（家族の名前）はソースに書かず、ここから読む。
struct AppConfig {
    let baseURL: URL?
    let token: String
    /// 名前選択画面に並べる候補。空なら自由入力だけになる
    let family: [String]

    static let shared = AppConfig(bundle: .main, arguments: ProcessInfo.processInfo.arguments)

    init(bundle: Bundle, arguments: [String] = []) {
        var rawURL = bundle.object(forInfoDictionaryKey: "FamEchoURL") as? String ?? ""
        var rawToken = bundle.object(forInfoDictionaryKey: "FamEchoToken") as? String ?? ""
        var rawFamily = bundle.object(forInfoDictionaryKey: "FamEchoFamily") as? String ?? ""
        #if DEBUG
        // UI テスト用（Debug ビルドで --uitest-reset のときだけ）: 送信先・トークン・名前候補を起動引数で差し替える。
        // Secrets.xcconfig を書き換えずに、テスト用の relay と一般名で回すため
        if arguments.contains("--uitest-reset") {
            if let v = Self.argument("--uitest-url", in: arguments) { rawURL = v }
            if let v = Self.argument("--uitest-token", in: arguments) { rawToken = v }
            if let v = Self.argument("--uitest-family", in: arguments) { rawFamily = v }
        }
        #endif
        rawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: rawURL), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil {
            baseURL = url
        } else {
            baseURL = nil
        }
        token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        family = Self.parseFamily(rawFamily)
    }

    /// 「名前A,名前B」→ ["名前A", "名前B"]。空白を除き、空・重複・長すぎる名前は落とす
    static func parseFamily(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").compactMap { part in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= SenderName.maxLength, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    private static func argument(_ key: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: key), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    /// 何が足りないかを短く（未設定時の表示用）
    var missingDescription: String? {
        switch (baseURL == nil, token.isEmpty) {
        case (true, true): return "送信先 URL とトークンが未設定です"
        case (true, false): return "送信先 URL が未設定です"
        case (false, true): return "トークンが未設定です"
        default: return nil
        }
    }

    var speakURL: URL? { baseURL?.appendingPathComponent("speak") }
    var healthURL: URL? { baseURL?.appendingPathComponent("health") }
}
