import Foundation

enum SpeakError: LocalizedError, Equatable {
    case notConfigured(String)
    case unauthorized
    case badRequest(String)
    case homeAssistant(code: String, detail: String)
    case server(Int)
    case unreachable
    case timedOut
    case other(String)

    /// 画面に出す短い理由
    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return what
        case .unauthorized: return "合言葉（トークン）が違います"
        case .badRequest(let detail): return detail
        case .homeAssistant(let code, let detail):
            switch code {
            case "ha_unreachable": return "Home Assistant が止まっているようです"
            case "ha_auth_failed": return "Home Assistant のトークンが無効です"
            case "ha_token_missing": return "Mac 側に Home Assistant のトークンがありません"
            case "no_targets": return "読み上げる Echo が見つかりません"
            default: return detail.isEmpty ? "Home Assistant でエラーになりました" : detail
            }
        case .server(let status): return "窓口がエラーを返しました（\(status)）"
        case .unreachable: return "家の Mac の窓口に届きません"
        case .timedOut: return "時間切れです（窓口から返事がありません）"
        case .other(let message): return message
        }
    }
}

struct SpeakResponse: Decodable {
    let ok: Bool
    let message: String?
}

private struct ErrorResponse: Decodable {
    let error: String?
    let detail: String?
}

struct HealthResponse: Decodable {
    struct HA: Decodable {
        let reachable: Bool
        let detail: String?
    }

    let status: String
    let ha: HA?
}

/// relay の POST /speak を叩く。読み上げ文（「〇〇から。」）は relay 側で組むので、ここでは素の文を送る。
struct SpeakClient {
    var config: AppConfig = .shared
    var session: URLSession = .shared

    func speak(from sender: String, text: String) async throws -> SpeakResponse {
        guard let url = config.speakURL, config.isConfigured else {
            throw SpeakError.notConfigured(config.missingDescription ?? "送信先が未設定です")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["from": sender, "text": text])

        let (data, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return (try? JSONDecoder().decode(SpeakResponse.self, from: data)) ?? SpeakResponse(ok: true, message: nil)
        case 401:
            throw SpeakError.unauthorized
        case 400, 413:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw SpeakError.badRequest(body?.detail ?? "送った文が受け付けられませんでした")
        case 502:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw SpeakError.homeAssistant(code: body?.error ?? "", detail: body?.detail ?? "")
        default:
            throw SpeakError.server(status)
        }
    }

    func health() async throws -> HealthResponse {
        guard let url = config.healthURL else {
            throw SpeakError.notConfigured(config.missingDescription ?? "送信先が未設定です")
        }
        let (data, response) = try await perform(URLRequest(url: url, timeoutInterval: 10))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let health = try? JSONDecoder().decode(HealthResponse.self, from: data) else {
            throw SpeakError.server(status)
        }
        return health
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw SpeakError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                throw SpeakError.unreachable
            default: throw SpeakError.other(error.localizedDescription)
            }
        }
    }
}
