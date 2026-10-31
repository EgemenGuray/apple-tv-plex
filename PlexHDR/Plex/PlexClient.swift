import Combine
import Foundation

enum PlexError: LocalizedError {
    case http(Int, String)
    case noServer
    case unreachable(String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case let .http(code, path): return "\(path) → HTTP \(code)"
        case .noServer: return "No Plex server selected"
        case let .unreachable(name): return "Could not reach \(name) on any address"
        case let .message(m): return m
        }
    }
}

/// plex.tv PIN sign-in, server discovery, library browsing, playback URLs and progress reporting.
@MainActor
final class PlexClient: ObservableObject {
    static let shared = PlexClient()

    static let product = "Plex HDR (\(Platform.plexPlatform))"
    static let version = "0.1.0"

    @Published private(set) var token: String?
    @Published private(set) var server: PlexServer?
    @Published private(set) var user: PlexUser?

    let clientId: String
    private let defaults = UserDefaults.standard
    private let session: URLSession

    private init() {
        if let id = defaults.string(forKey: "clientId") {
            clientId = id
        } else {
            clientId = UUID().uuidString
            defaults.set(clientId, forKey: "clientId")
        }
        token = defaults.string(forKey: "token")
        server = Self.load(PlexServer.self, "server")
        user = Self.load(PlexUser.self, "user")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        session = URLSession(configuration: cfg)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let d = try? JSONEncoder().encode(value) { defaults.set(d, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    var headers: [String: String] {
        [
            "X-Plex-Product": Self.product,
            "X-Plex-Version": Self.version,
            "X-Plex-Client-Identifier": clientId,
            "X-Plex-Platform": Platform.plexPlatform,
            "X-Plex-Platform-Version": Platform.systemVersion,
            "X-Plex-Device": Platform.plexDevice,
            "X-Plex-Device-Name": Platform.deviceName,
            "X-Plex-Provides": "player",
        ]
    }

    // MARK: - HTTP

    func request(_ method: String = "GET", _ url: URL, token: String? = nil, timeout: TimeInterval = 15, accept: String = "application/json") async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(accept, forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let token { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PlexError.http(code, url.path) }
        return data
    }

    func json(_ method: String = "GET", _ url: URL, token: String? = nil, timeout: TimeInterval = 15) async throws -> Any {
        let data = try await request(method, url, token: token, timeout: timeout)
        if data.isEmpty { return JSON() }
        return (try? JSONSerialization.jsonObject(with: data)) ?? JSON()
    }

    nonisolated static func url(_ base: String, _ path: String, _ params: [String: Any?] = [:]) -> URL {
        var c = URLComponents(string: base + path)!
        let items = params.compactMap { k, v -> URLQueryItem? in
            guard let v else { return nil }
            return URLQueryItem(name: k, value: "\(v)")
        }.sorted { $0.name < $1.name }
        if !items.isEmpty { c.queryItems = (c.queryItems ?? []) + items }
        // "+" is legal in a query but Plex reads it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    // MARK: - Sign-in (plex.tv/link)

    struct Pin { let id: Int; let code: String }

    /// strong = false gives the 4-character code for plex.tv/link; strong = true gives the long code the QR sign-in page uses.
    func createPin(strong: Bool = false) async throws -> Pin {
        let r = try await json("POST", Self.url("https://plex.tv", "/api/v2/pins", ["strong": strong ? "true" : "false"])) as? JSON ?? [:]
        guard let id = (r["id"] as? NSNumber)?.intValue, let code = r["code"] as? String else { throw PlexError.message("plex.tv did not return a code") }
        return Pin(id: id, code: code)
    }

    /// Plex's sign-in page for this PIN, for the QR code: opening it on a phone where you're signed in to Plex
    /// approves the Apple TV without typing the code.
    func authURL(code: String) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        var q = URLComponents()
        q.queryItems = [
            URLQueryItem(name: "clientID", value: clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "context[device][product]", value: Self.product),
        ]
        c.fragment = "?" + (q.percentEncodedQuery ?? "")
        return c.url!
    }

    /// Returns true once the code has been entered at plex.tv/link.
    func checkPin(_ pin: Pin) async throws -> Bool {
        let r = try await json("GET", Self.url("https://plex.tv", "/api/v2/pins/\(pin.id)")) as? JSON ?? [:]
        guard let t = r["authToken"] as? String, !t.isEmpty else { return false }
        token = t
        defaults.set(t, forKey: "token")
        _ = try? await account()
        return true
    }

    func signOut() {
        token = nil; server = nil; user = nil
        defaults.removeObject(forKey: "token"); save(nil as PlexServer?, "server"); save(nil as PlexUser?, "user")
    }

    @discardableResult
    func account() async throws -> PlexUser {
        let u = try await json("GET", Self.url("https://plex.tv", "/api/v2/user"), token: token) as? JSON ?? [:]
        let pu = PlexUser(title: (u["title"] as? String) ?? (u["username"] as? String) ?? "", thumb: u["thumb"] as? String, uuid: u["uuid"] as? String)
        user = pu; save(pu, "user")
        return pu
    }

    // MARK: - Plex Home users

    struct HomeUser: Identifiable { let raw: JSON
        var id: String { raw["uuid"] as? String ?? "" }
        var title: String { raw["title"] as? String ?? "" }
        var thumb: String? { raw["thumb"] as? String }
        var protected: Bool { (raw["protected"] as? Bool) ?? ((raw["protected"] as? NSNumber)?.boolValue ?? false) }
        var admin: Bool { (raw["admin"] as? Bool) ?? false }
    }

    func homeUsers() async throws -> [HomeUser] {
        let r = try await json("GET", Self.url("https://plex.tv", "/api/v2/home/users"), token: token)
        let list = (r as? JSON)?["users"] as? [JSON] ?? (r as? [JSON]) ?? []
        return list.map(HomeUser.init)
    }

    /// Switching gives a token for that user; the server must then be re-resolved, because its access token is per user.
    func switchUser(_ u: HomeUser, pin: String?) async throws {
        let url = Self.url("https://plex.tv", "/api/v2/home/users/\(u.id)/switch", ["pin": pin])
        let r = try await json("POST", url, token: token) as? JSON ?? [:]
        guard let t = r["authToken"] as? String else { throw PlexError.message("Plex did not accept the switch") }
        let machineId = server?.machineId
        token = t; defaults.set(t, forKey: "token")
        let pu = PlexUser(title: (r["title"] as? String) ?? u.title, thumb: (r["thumb"] as? String) ?? u.thumb, uuid: (r["uuid"] as? String) ?? u.id)
        user = pu; save(pu, "user")
        server = nil; save(nil as PlexServer?, "server")
        let servers = try await listServers()
        if let same = servers.first(where: { $0["clientIdentifier"] as? String == machineId }) ?? servers.first {
            try await connect(same)
        }
    }

    // MARK: - Servers

    func listServers() async throws -> [JSON] {
        let r = try await json("GET", Self.url("https://plex.tv", "/api/v2/resources", ["includeHttps": 1, "includeRelay": 1]), token: token)
        return (r as? [JSON] ?? []).filter { ($0["provides"] as? String ?? "").contains("server") }
    }

    /// Tries the server's connections, local first and relay last, and keeps the first one that answers.
    @discardableResult
    func connect(_ resource: JSON) async throws -> PlexServer {
        let conns = (resource["connections"] as? [JSON] ?? []).sorted { a, b in
            let ar = (a["relay"] as? Bool) ?? false, br = (b["relay"] as? Bool) ?? false
            if ar != br { return !ar }
            return ((a["local"] as? Bool) ?? false) && !((b["local"] as? Bool) ?? false)
        }
        let tok = resource["accessToken"] as? String ?? token ?? ""
        let name = resource["name"] as? String ?? "Plex"
        for c in conns {
            guard let uri = c["uri"] as? String else { continue }
            do {
                _ = try await request("GET", Self.url(uri, "/identity"), token: tok, timeout: 4)
                let s = PlexServer(name: name, uri: uri, token: tok, machineId: resource["clientIdentifier"] as? String ?? "", relay: (c["relay"] as? Bool) ?? false)
                server = s; save(s, "server")
                return s
            } catch { continue }
        }
        throw PlexError.unreachable(name)
    }

    // MARK: - Library

    func api(_ path: String, _ params: [String: Any?] = [:]) async throws -> JSON {
        guard let server else { throw PlexError.noServer }
        let r = try await json("GET", Self.url(server.uri, path, params), token: server.token)
        return (r as? JSON)?["MediaContainer"] as? JSON ?? [:]
    }

    private func items(_ mc: JSON) -> [PlexItem] { (mc["Metadata"] as? [JSON] ?? []).map(PlexItem.init) }

    func sections() async throws -> [PlexSection] {
        (try await api("/library/sections")["Directory"] as? [JSON] ?? []).map(PlexSection.init)
    }

    struct ItemQuery {
        var sort = "titleSort"
        var unwatched = false
        var genre: String?
        var start = 0
        var size = 100
        var person: (kind: PlexPerson.Kind, id: String)?
    }

    func sectionItems(_ id: String, _ q: ItemQuery) async throws -> (items: [PlexItem], total: Int) {
        var p: [String: Any?] = [
            "X-Plex-Container-Start": q.start, "X-Plex-Container-Size": q.size,
            "sort": q.sort, "unwatched": q.unwatched ? 1 : nil, "genre": q.genre, "includeGuids": 1,
        ]
        if let person = q.person { p[person.kind.rawValue] = person.id }
        let mc = try await api("/library/sections/\(id)/all", p)
        let list = items(mc)
        return (list, (mc["totalSize"] as? NSNumber)?.intValue ?? list.count)
    }

    func recentlyAdded(_ sectionId: String, size: Int = 20) async throws -> [PlexItem] {
        items(try await api("/library/sections/\(sectionId)/recentlyAdded", ["X-Plex-Container-Start": 0, "X-Plex-Container-Size": size, "includeGuids": 1]))
    }

    struct Genre: Hashable, Identifiable { let key: String; let title: String; var id: String { key } }

    func genres(_ sectionId: String) async throws -> [Genre] {
        (try await api("/library/sections/\(sectionId)/genre")["Directory"] as? [JSON] ?? []).compactMap {
            guard let k = ($0["key"] as? String) ?? ($0["key"] as? NSNumber)?.stringValue, let t = $0["title"] as? String else { return nil }
            return Genre(key: k, title: t)
        }
    }

    func collections(_ sectionId: String) async throws -> [PlexItem] { items(try await api("/library/sections/\(sectionId)/collections")) }
    func collectionItems(_ ratingKey: String) async throws -> [PlexItem] { items(try await api("/library/collections/\(ratingKey)/children")) }
    func onDeck() async throws -> [PlexItem] { items(try await api("/library/onDeck", ["includeGuids": 1])) }

    /// Chapters, intro/credits markers, extras, the show's next-up episode, cast and crew in one call.
    func metadata(_ ratingKey: String) async throws -> PlexItem? {
        items(try await api("/library/metadata/\(ratingKey)", [
            "includeChapters": 1, "includeMarkers": 1, "includeExtras": 1, "includeOnDeck": 1, "includeGuids": 1,
        ])).first
    }

    func children(_ ratingKey: String) async throws -> [PlexItem] { items(try await api("/library/metadata/\(ratingKey)/children")) }

    func similar(_ ratingKey: String) async -> [PlexItem] {
        (try? items(await api("/library/metadata/\(ratingKey)/similar", ["count": 20]))) ?? []
    }

    /// Every movie and show in the movie and TV libraries that this person is credited on, newest first.
    func personItems(_ person: PlexPerson) async -> [PlexItem] {
        guard let tagId = person.tagId, let secs = try? await sections() else { return [] }
        var out: [PlexItem] = []
        for s in secs where s.isVideo {
            var q = ItemQuery(); q.sort = "originallyAvailableAt:desc"; q.size = 300; q.person = (person.kind, tagId)
            out += (try? await sectionItems(s.id, q).items) ?? []
        }
        return out.sorted { ($0.originallyAvailableAt ?? "") > ($1.originallyAvailableAt ?? "") }
    }

    func search(_ query: String) async throws -> [PlexItem] {
        let mc = try await api("/hubs/search", ["query": query, "limit": 20, "includeCollections": 1])
        return (mc["Hub"] as? [JSON] ?? []).flatMap { hub -> [PlexItem] in
            guard ["movie", "show", "episode", "collection"].contains(hub["type"] as? String ?? "") else { return [] }
            return (hub["Metadata"] as? [JSON] ?? []).map(PlexItem.init)
        }
    }

    func setWatched(_ item: PlexItem, _ watched: Bool) async {
        guard let server, let rk = item.ratingKey else { return }
        _ = try? await request("GET", Self.url(server.uri, watched ? "/:/scrobble" : "/:/unscrobble", ["key": rk, "identifier": "com.plexapp.plugins.library"]), token: server.token)
    }

    /// Next episode after this one: the next in its season, else the first episode of the next season.
    func nextEpisode(after ep: PlexItem) async -> PlexItem? {
        guard ep.type == "episode", let season = ep.parentRatingKey else { return nil }
        let eps = (try? await children(season)) ?? []
        var next = eps.filter { ($0.index ?? 0) > (ep.index ?? 0) }.min { ($0.index ?? 0) < ($1.index ?? 0) }
        if next == nil, let show = ep.grandparentRatingKey {
            let seasons = (try? await children(show)) ?? []
            if let ns = seasons.filter({ ($0.index ?? 0) > (ep.parentIndex ?? 0) }).min(by: { ($0.index ?? 0) < ($1.index ?? 0) }), let rk = ns.ratingKey {
                next = try? await children(rk).first
            }
        }
        guard let rk = next?.ratingKey else { return nil }
        return try? await metadata(rk)
    }

    // MARK: - Artwork

    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, let server else { return nil }
        if path.hasPrefix("http") && !path.contains(server.uri) {
            // Absolute URLs (TMDB, plex.tv avatars) are used as they are.
            return URL(string: path)
        }
        return Self.url(server.uri, "/photo/:/transcode", [
            "width": width, "height": height, "minSize": 1, "upscale": 1, "url": path, "X-Plex-Token": server.token,
        ])
    }

    // MARK: - Playback

    /// The original file over HTTP. The app's own FFmpeg player demuxes and decodes it, so nothing is converted.
    func directPlayURL(_ part: PlexPart) -> URL? {
        guard let server, let key = part.key else { return nil }
        return Self.url(server.uri, key, ["X-Plex-Token": server.token, "X-Plex-Client-Identifier": clientId])
    }

    /// HLS with video and audio both copied: the server only changes the container, so AVPlayer (and its Dolby Atmos
    /// decoder) can play an MKV. Nothing is re-encoded.
    /// `h264Only`: when AVPlayer won't take HEVC from the server's HLS stream, the server converts the video to H.264
    /// (SDR) as a last resort so the title still plays.
    func remuxURL(_ item: PlexItem, mediaIndex: Int, offset: TimeInterval, session: String, h264Only: Bool = false) -> URL? {
        guard let server, let rk = item.ratingKey else { return nil }
        let video = h264Only ? "h264" : "hevc,h264"
        let extra = [
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=\(video)&audioCodec=eac3,ac3,aac)",
            "add-direct-play-profile(type=videoProfile&container=mp4,mov&videoCodec=\(video)&audioCodec=eac3,ac3,aac)",
        ].joined(separator: "+")
        var p: [String: Any?] = [:]
        for (k, v) in headers { p[k] = v }
        p["X-Plex-Token"] = server.token
        p["X-Plex-Client-Profile-Name"] = "Generic"
        p["X-Plex-Client-Profile-Extra"] = extra
        p["X-Plex-Session-Identifier"] = session
        p["path"] = "/library/metadata/\(rk)"
        p["mediaIndex"] = mediaIndex
        p["partIndex"] = 0
        p["protocol"] = "hls"
        p["fastSeek"] = 1
        p["directPlay"] = 0
        p["directStream"] = 1
        p["directStreamAudio"] = 1
        p["videoQuality"] = 100
        p["maxVideoBitrate"] = 200_000
        p["videoResolution"] = h264Only ? "1920x1080" : "3840x2160"
        p["subtitles"] = "none"
        p["offset"] = Int(offset)
        p["session"] = session
        return Self.url(server.uri, "/video/:/transcode/universal/start.m3u8", p)
    }

    func stopTranscode(_ session: String) async {
        guard let server else { return }
        _ = try? await request("GET", Self.url(server.uri, "/video/:/transcode/universal/stop", ["session": session]), token: server.token)
    }

    /// A subtitle stream inside the file, as a file of its own (used where the player can't read the container).
    func streamFileURL(_ stream: PlexStream) -> URL? {
        guard let server else { return nil }
        return Self.url(server.uri, "/library/streams/\(stream.id)", ["X-Plex-Token": server.token, "format": "srt", "encoding": "utf-8"])
    }

    func subtitleURL(_ stream: PlexStream) -> URL? {
        guard let server, let key = stream.key else { return nil }
        if key.hasPrefix("http") { return URL(string: key) }
        return Self.url(server.uri, key, ["X-Plex-Token": server.token])
    }

    /// Trick-play thumbnails (BIF), generated by the server when "video preview thumbnails" is on.
    func previewIndex(_ part: PlexPart) async -> Data? {
        guard let server, let id = part.id, (part.indexes ?? "").contains("sd") else { return nil }
        return try? await request("GET", Self.url(server.uri, "/library/parts/\(id)/indexes/sd"), token: server.token, timeout: 60, accept: "*/*")
    }

    /// Persists the chosen audio/subtitle stream on the server, so other clients use the same tracks next time.
    func selectStreams(partId: Int, audio: Int?, subtitle: Int?) async {
        guard let server else { return }
        var p: [String: Any?] = ["allParts": 1]
        if let audio { p["audioStreamID"] = audio }
        if let subtitle { p["subtitleStreamID"] = subtitle }
        _ = try? await request("PUT", Self.url(server.uri, "/library/parts/\(partId)", p), token: server.token)
    }

    func timeline(_ item: PlexItem, state: String, time: TimeInterval, duration: TimeInterval) async {
        guard let server, let rk = item.ratingKey else { return }
        _ = try? await request("GET", Self.url(server.uri, "/:/timeline", [
            "ratingKey": rk, "key": "/library/metadata/\(rk)", "state": state,
            "time": Int(time * 1000), "duration": Int(duration * 1000),
        ]), token: server.token)
    }

    // MARK: - Server subtitle search (the server's own OpenSubtitles agent)

    func searchServerSubtitles(_ item: PlexItem, language: String) async -> [PlexStream] {
        guard let rk = item.ratingKey else { return [] }
        let mc = (try? await api("/library/metadata/\(rk)/subtitles", ["language": language, "hearingImpaired": 0, "forced": 0])) ?? [:]
        return (mc["Stream"] as? [JSON] ?? []).map(PlexStream.init)
    }

    func saveServerSubtitle(_ item: PlexItem, _ result: PlexStream) async throws {
        guard let server, let rk = item.ratingKey else { return }
        _ = try await request("PUT", Self.url(server.uri, "/library/metadata/\(rk)/subtitles", [
            "key": result.key, "codec": result.codec, "language": result.languageCode,
            "hearingImpaired": result.hearingImpaired ? 1 : 0, "forced": result.forced ? 1 : 0,
            "providerTitle": result.string("providerTitle"),
        ]), token: server.token)
    }
}
