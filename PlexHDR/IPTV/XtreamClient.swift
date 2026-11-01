import Foundation

/// Xtream Codes "player_api.php": account, categories, live channels, films and series.
struct XtreamClient {
    let base: String
    let username: String
    let password: String
    var userAgent: String?

    init(playlist: IPTVPlaylist) {
        base = XtreamClient.normalize(playlist.url)
        username = playlist.username
        password = playlist.password
        userAgent = playlist.userAgent.isEmpty ? nil : playlist.userAgent
    }

    /// "host:port", "http://host:port/", "http://host/player_api.php?..." → "http://host:port".
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        for suffix in ["/player_api.php", "/get.php", "/xmltv.php", "/c", "/"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&="))) ?? s }

    func apiURL(_ action: String?, _ extra: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: base + "/player_api.php")
        var q = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { q.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra { q.append(URLQueryItem(name: k, value: v)) }
        c?.queryItems = q
        return c?.url
    }

    var epgURL: String {
        var c = URLComponents(string: base + "/xmltv.php")
        c?.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        return c?.url?.absoluteString ?? ""
    }

    func liveURL(_ id: Int, ext: String) -> String { "\(base)/live/\(enc(username))/\(enc(password))/\(id).\(ext)" }
    func movieURL(_ id: Int, ext: String) -> String { "\(base)/movie/\(enc(username))/\(enc(password))/\(id).\(ext)" }
    func seriesURL(_ id: Int, ext: String) -> String { "\(base)/series/\(enc(username))/\(enc(password))/\(id).\(ext)" }

    /// Past programme: /timeshift/user/pass/<minutes>/<YYYY-MM-DD:HH-MM in server time>/<id>.ts
    func timeshiftURL(_ id: Int, start: Date, minutes: Int, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        return "\(base)/timeshift/\(enc(username))/\(enc(password))/\(minutes)/\(f.string(from: start))/\(id).ts"
    }

    func get(_ action: String?, _ extra: [String: String] = [:]) async throws -> Any {
        guard let url = apiURL(action, extra) else { throw IPTVError.message("The server address isn't valid.") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw IPTVError.message(h.statusCode == 401 || h.statusCode == 403 ? "The username or password was refused." : "The server answered \(h.statusCode).")
        }
        if data.isEmpty { return [Any]() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Lists come back as arrays, or as objects keyed by id on some panels.
    private func list(_ v: Any) -> [[String: Any]] {
        if let a = v as? [[String: Any]] { return a }
        if let d = v as? [String: Any] { return d.values.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// Everything for the source: account, live channels, films and series.
    func load(playlist: IPTVPlaylist, liveExtension: String) async throws -> IPTVContent {
        var content = IPTVContent()
        let pid = playlist.id
        let auth = try await get(nil)
        guard let root = auth as? [String: Any], let user = root["user_info"] as? [String: Any] else {
            throw IPTVError.message("This doesn't look like an Xtream Codes server.")
        }
        if Loose.int(user["auth"]) == 0 { throw IPTVError.message("The username or password was refused.") }
        content.account = IPTVAccount(status: Loose.string(user["status"]), expires: Loose.date(user["exp_date"]),
                                      maxConnections: Loose.int(user["max_connections"]), activeConnections: Loose.int(user["active_cons"]),
                                      trial: Loose.bool(user["is_trial"]))
        if let server = root["server_info"] as? [String: Any] { content.serverTimeZone = Loose.string(server["timezone"]) }
        content.epgURLs = [epgURL]

        async let liveCats = get("get_live_categories")
        async let liveStreams = get("get_live_streams")
        async let vodCats = get("get_vod_categories")
        async let vodStreams = get("get_vod_streams")
        async let seriesCats = get("get_series_categories")
        async let seriesList = get("get_series")

        func names(_ v: Any) -> ([String: String], [String]) {
            var map: [String: String] = [:]
            var order: [String] = []
            for c in list(v) {
                guard let id = Loose.string(c["category_id"]), let n = Loose.string(c["category_name"]) else { continue }
                map[id] = n
                order.append(n)
            }
            return (map, order)
        }

        let (liveMap, liveOrder) = names((try? await liveCats) ?? [Any]())
        var liveGroups = OrderedSet()
        liveOrder.forEach { liveGroups.insert($0) }
        for s in list((try? await liveStreams) ?? [Any]()) {
            guard let id = Loose.int(s["stream_id"]) else { continue }
            let name = Loose.string(s["name"]) ?? "Channel \(id)"
            let group = Loose.string(s["category_id"]).flatMap { liveMap[$0] } ?? "Other"
            liveGroups.insert(group)
            let archive = Loose.bool(s["tv_archive"])
            let days = Loose.int(s["tv_archive_duration"]) ?? 0
            content.channels.append(IPTVChannel(
                id: "\(pid.uuidString)|\(id)", playlistID: pid, name: name, number: Loose.int(s["num"]),
                logo: Loose.string(s["stream_icon"]), group: group, url: liveURL(id, ext: liveExtension),
                epgID: Loose.string(s["epg_channel_id"]),
                catchup: archive && days > 0 ? IPTVCatchup(mode: "xc", days: days, source: nil) : nil,
                userAgent: userAgent, streamID: id))
        }
        content.liveGroups = liveGroups.items.filter { g in content.channels.contains { $0.group == g } }

        let (vodMap, vodOrder) = names((try? await vodCats) ?? [Any]())
        var movieGroups = OrderedSet()
        vodOrder.forEach { movieGroups.insert($0) }
        for s in list((try? await vodStreams) ?? [Any]()) {
            guard let id = Loose.int(s["stream_id"]) else { continue }
            let group = Loose.string(s["category_id"]).flatMap { vodMap[$0] } ?? "Other"
            movieGroups.insert(group)
            let ext = Loose.string(s["container_extension"]) ?? "mp4"
            let raw = Loose.string(s["name"]) ?? "Film \(id)"
            let (title, year) = M3UParser.splitYear(raw)
            content.movies.append(IPTVMovie(
                id: "\(pid.uuidString)|m|\(id)", playlistID: pid, name: title, poster: Loose.string(s["stream_icon"]),
                group: group, url: movieURL(id, ext: ext), rating: Loose.double(s["rating"]).flatMap { $0 > 0 ? $0 : nil },
                year: year ?? Loose.year(s["year"]) ?? Loose.year(s["releasedate"]), added: Loose.date(s["added"]), streamID: id, plot: Loose.string(s["plot"])))
        }
        content.movieGroups = movieGroups.items.filter { g in content.movies.contains { $0.group == g } }

        let (seriesMap, seriesOrder) = names((try? await seriesCats) ?? [Any]())
        var seriesGroups = OrderedSet()
        seriesOrder.forEach { seriesGroups.insert($0) }
        for s in list((try? await seriesList) ?? [Any]()) {
            guard let id = Loose.int(s["series_id"]) else { continue }
            let group = Loose.string(s["category_id"]).flatMap { seriesMap[$0] } ?? "Other"
            seriesGroups.insert(group)
            content.series.append(IPTVSeries(
                id: "\(pid.uuidString)|s|\(id)", playlistID: pid, name: Loose.string(s["name"]) ?? "Series \(id)",
                poster: Loose.string(s["cover"]), group: group, plot: Loose.string(s["plot"]),
                rating: Loose.double(s["rating"]).flatMap { $0 > 0 ? $0 : nil },
                year: Loose.year(s["releaseDate"]) ?? Loose.year(s["release_date"]) ?? Loose.year(s["year"]),
                genre: Loose.string(s["genre"]), seriesID: id, episodes: nil))
        }
        content.seriesGroups = seriesGroups.items.filter { g in content.series.contains { $0.group == g } }
        return content
    }

    func movieDetails(_ id: Int) async throws -> IPTVDetails {
        let v = try await get("get_vod_info", ["vod_id": String(id)])
        let info = (v as? [String: Any])?["info"] as? [String: Any] ?? [:]
        return details(info)
    }

    func seriesDetails(_ id: Int) async throws -> IPTVDetails {
        let v = try await get("get_series_info", ["series_id": String(id)])
        guard let root = v as? [String: Any] else { return IPTVDetails() }
        var d = details(root["info"] as? [String: Any] ?? [:])
        var eps: [IPTVEpisode] = []
        var groups: [[String: Any]] = []
        if let byseason = root["episodes"] as? [String: Any] {
            for (_, list) in byseason { groups += (list as? [[String: Any]]) ?? [] }
        } else if let arr = root["episodes"] as? [[Any]] {
            for list in arr { groups += list.compactMap { $0 as? [String: Any] } }
        } else if let arr = root["episodes"] as? [[String: Any]] {
            groups = arr
        }
        for e in groups {
            guard let eid = Loose.int(e["id"]) else { continue }
            let info = e["info"] as? [String: Any] ?? [:]
            let ext = Loose.string(e["container_extension"]) ?? "mp4"
            eps.append(IPTVEpisode(
                id: "x|\(id)|\(eid)", season: Loose.int(e["season"]) ?? 1, number: Loose.int(e["episode_num"]) ?? 0,
                title: Loose.string(e["title"]) ?? "Episode", url: seriesURL(eid, ext: ext), plot: Loose.string(info["plot"]),
                thumb: Loose.string(info["movie_image"]) ?? Loose.string(info["cover_big"]),
                duration: Loose.double(info["duration_secs"])))
        }
        d.episodes = eps.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        return d
    }

    private func details(_ info: [String: Any]) -> IPTVDetails {
        var d = IPTVDetails()
        d.plot = Loose.string(info["plot"]) ?? Loose.string(info["description"])
        d.cast = Loose.string(info["cast"]) ?? Loose.string(info["actors"])
        d.director = Loose.string(info["director"])
        d.genre = Loose.string(info["genre"])
        d.released = Loose.string(info["releasedate"]) ?? Loose.string(info["releaseDate"]) ?? Loose.string(info["release_date"])
        d.duration = Loose.double(info["duration_secs"]) ?? Loose.double(info["episode_run_time"]).map { $0 * 60 }
        d.rating = Loose.double(info["rating"]).flatMap { $0 > 0 ? $0 : nil }
        if let arr = info["backdrop_path"] as? [Any] { d.backdrop = arr.compactMap { Loose.string($0) }.first }
        else { d.backdrop = Loose.string(info["backdrop_path"]) }
        d.poster = Loose.string(info["movie_image"]) ?? Loose.string(info["cover_big"]) ?? Loose.string(info["cover"])
        d.trailer = Loose.string(info["youtube_trailer"])
        return d
    }
}
