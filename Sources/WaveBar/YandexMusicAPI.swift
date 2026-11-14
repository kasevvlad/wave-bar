import CryptoKit
import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct FlexibleID: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}

struct Artist: Decodable, Hashable {
    let name: String
}

struct Album: Decodable, Hashable {
    let id: FlexibleID
}

struct Track: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let version: String?
    let artists: [Artist]
    let albums: [Album]
    let coverUri: String?
    let durationMs: Int?
    let available: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, version, artists, albums, coverUri, durationMs, available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleID.self, forKey: .id).value
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Без названия"
        version = try c.decodeIfPresent(String.self, forKey: .version)
        artists = try c.decodeIfPresent([Artist].self, forKey: .artists) ?? []
        albums = try c.decodeIfPresent([Album].self, forKey: .albums) ?? []
        coverUri = try c.decodeIfPresent(String.self, forKey: .coverUri)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        available = try c.decodeIfPresent(Bool.self, forKey: .available)
    }

    var artistLine: String {
        artists.isEmpty ? "Неизвестный исполнитель" : artists.map(\.name).joined(separator: ", ")
    }

    var albumID: String? { albums.first?.id.value }

    var fullID: String { albumID.map { "\(id):\($0)" } ?? id }

    var duration: Double { Double(durationMs ?? 0) / 1000 }

    func coverURL(size: Int) -> URL? {
        guard let coverUri else { return nil }
        return URL(string: "https://" + coverUri.replacingOccurrences(of: "%%", with: "\(size)x\(size)"))
    }
}

struct Account {
    let uid: String
    let name: String
    let hasPlus: Bool
}

final class YandexMusicAPI {
    private let token: String
    private let base = URL(string: "https://api.music.yandex.net")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static let waveStation = "user:onyourwave"

    init(token: String) {
        self.token = token
    }

    // MARK: Account

    func account() async throws -> Account {
        struct Status: Decodable {
            struct AccountInfo: Decodable {
                let uid: FlexibleID?
                let login: String?
                let displayName: String?
            }
            struct Plus: Decodable { let hasPlus: Bool? }
            let account: AccountInfo
            let plus: Plus?
        }
        let status: Status = try await get("/account/status")
        guard let uid = status.account.uid?.value else {
            throw APIError(message: "Не удалось войти: токен недействителен")
        }
        let name = status.account.displayName ?? status.account.login ?? "Яндекс"
        return Account(uid: uid, name: name, hasPlus: status.plus?.hasPlus ?? false)
    }

    // MARK: Library

    func likedTrackIDs(uid: String) async throws -> [String] {
        struct Likes: Decodable {
            struct Library: Decodable {
                struct Item: Decodable {
                    let id: FlexibleID
                    let albumId: FlexibleID?
                }
                let tracks: [Item]
            }
            let library: Library
        }
        let likes: Likes = try await get("/users/\(uid)/likes/tracks", query: ["if-modified-since-revision": "0"])
        return likes.library.tracks.map { item in
            item.albumId.map { "\(item.id.value):\($0.value)" } ?? item.id.value
        }
    }

    func tracks(ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        return try await send("/tracks", method: "POST", form: ["track-ids": ids.joined(separator: ","), "with-positions": "false"])
    }

    func setLiked(_ liked: Bool, trackID: String, uid: String) async throws {
        let path = liked ? "/users/\(uid)/likes/tracks/add-multiple" : "/users/\(uid)/likes/tracks/remove"
        _ = try await raw(path, method: "POST", form: ["track-ids": trackID])
    }

    // MARK: My Wave

    func waveTracks(after trackID: String?) async throws -> (tracks: [Track], batchID: String?) {
        struct Batch: Decodable {
            struct Item: Decodable { let track: Track? }
            let sequence: [Item]
            let batchId: String?
        }
        var query = ["settings2": "true"]
        if let trackID { query["queue"] = trackID }
        let batch: Batch = try await get("/rotor/station/\(Self.waveStation)/tracks", query: query)
        return (batch.sequence.compactMap(\.track), batch.batchId)
    }

    func waveFeedback(_ type: String, track: Track?, batchID: String?, played: Double? = nil) async {
        var body: [String: Any] = ["type": type, "timestamp": Date().timeIntervalSince1970]
        if type == "radioStarted" { body["from"] = "wavebar" }
        if let track { body["trackId"] = track.fullID }
        if let played { body["totalPlayedSeconds"] = played }
        var query: [String: String] = [:]
        if let batchID { query["batch-id"] = batchID }
        _ = try? await raw("/rotor/station/\(Self.waveStation)/feedback", method: "POST", query: query, json: body)
    }

    // MARK: Streaming

    func streamURL(trackID: String) async throws -> URL {
        do {
            return try await legacyStreamURL(trackID: trackID)
        } catch {
            return try await fileInfoStreamURL(trackID: trackID)
        }
    }

    private func legacyStreamURL(trackID: String) async throws -> URL {
        struct Info: Decodable {
            let codec: String
            let bitrateInKbps: Int
            let downloadInfoUrl: String
            let preview: Bool?
        }
        let infos: [Info] = try await get("/tracks/\(trackID)/download-info")
        let best = infos
            .filter { $0.codec == "mp3" }
            .sorted { ($0.preview == true ? 0 : 1, $0.bitrateInKbps) > ($1.preview == true ? 0 : 1, $1.bitrateInKbps) }
            .first
        guard let best, let infoURL = URL(string: best.downloadInfoUrl) else {
            throw APIError(message: "Трек недоступен для прослушивания")
        }
        let (data, _) = try await session.data(from: infoURL)
        let xml = String(decoding: data, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let open = xml.range(of: "<\(name)>"),
                  let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
            return String(xml[open.upperBound..<close.lowerBound])
        }
        guard let host = tag("host"), let path = tag("path"), let ts = tag("ts"), let s = tag("s") else {
            throw APIError(message: "Не удалось получить ссылку на трек")
        }
        let digest = Insecure.MD5.hash(data: Data(("XGRlBW9FXlekgbPrRHuSiA" + path.dropFirst() + s).utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "https://\(host)/get-mp3/\(sign)/\(ts)\(path)") else {
            throw APIError(message: "Не удалось получить ссылку на трек")
        }
        return url
    }

    private func fileInfoStreamURL(trackID: String) async throws -> URL {
        struct FileInfo: Decodable {
            struct Download: Decodable {
                let url: String?
                let urls: [String]?
            }
            let downloadInfo: Download
        }
        let plainID = String(trackID.split(separator: ":").first ?? Substring(trackID))
        let ts = String(Int(Date().timeIntervalSince1970))
        let quality = "nq"
        let codecs = "mp3,aac,he-aac"
        let transports = "raw"
        let payload = ts + plainID + quality + codecs.replacingOccurrences(of: ",", with: "") + transports
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data("p93jhgh689SBReK6ghtw62".utf8)))
        let sign = String(Data(mac).base64EncodedString().dropLast())
        let info: FileInfo = try await get("/get-file-info", query: [
            "ts": ts, "trackId": plainID, "quality": quality,
            "codecs": codecs, "transports": transports, "sign": sign,
        ])
        guard let link = info.downloadInfo.url ?? info.downloadInfo.urls?.first, let url = URL(string: link) else {
            throw APIError(message: "Трек недоступен для прослушивания")
        }
        return url
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable { let result: T }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let name: String?
            let message: String?
        }
        let error: Body
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(path, query: query)
    }

    private func send<T: Decodable>(
        _ path: String, method: String = "GET", query: [String: String] = [:], form: [String: String]? = nil
    ) async throws -> T {
        let data = try await raw(path, method: method, query: query, form: form)
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data).result
        } catch {
            throw APIError(message: "Неожиданный ответ сервера")
        }
    }

    @discardableResult
    private func raw(
        _ path: String, method: String = "GET", query: [String: String] = [:],
        form: [String: String]? = nil, json: [String: Any]? = nil
    ) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        } else if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 {
                throw APIError(message: "Сессия истекла, войдите заново")
            }
            let body = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw APIError(message: body?.error.message ?? body?.error.name ?? "Ошибка сервера (\(status))")
        }
        return data
    }
}
