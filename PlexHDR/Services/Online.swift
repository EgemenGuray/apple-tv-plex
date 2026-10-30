import Foundation

/// Internet services, the way Infuse uses them: TMDB for artwork Plex doesn't have (title logos, backdrops, posters),
/// ratings from IMDb / Rotten Tomatoes / Metacritic / Letterboxd, and OpenSubtitles (matched by file hash first).
/// All need your own free API keys: Settings → Online services, or Keys.swift.
@MainActor
final class Online {
    static let shared = Online()

    private let tmdbBase = "https://api.themoviedb.org/3"
    private let tmdbImages = "https://image.tmdb.org/t/p/"
    private let osBase = "https://api.opensubtitles.com/api/v1"
    private let appUA = "PlexHDR-tvOS v0.1"
    private var settings: AppSettings { .shared }
    private let session = URLSession(configuration: .default)
    private let defaults = UserDefaults.standard

    // MARK: - HTTP

    private func get(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Any? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? JSON)?["message"] as? String
            throw PlexError.message(msg ?? "HTTP \(code)")
        }
        return data
    }

    private func getJSON(_ url: URL, headers: [String: String] = [:], method: String = "GET", body: Any? = nil) async throws -> JSON {
        let d = try await get(url, headers: headers, method: method, body: body)
        return (try? JSONSerialization.jsonObject(with: d) as? JSON) ?? [:]
    }

    // MARK: - TMDB artwork

    struct Artwork: Codable { var logo: String?; var backdrop: String?; var poster: String? }
    private var artCache: [String: Artwork] = {
        (try? JSONDecoder().decode([String: Artwork].self, from: UserDefaults.standard.data(forKey: "tmdbArt") ?? Data())) ?? [:]
    }()
    private var artPending: [String: Task<Artwork?, Never>] = [:]

    private func tmdb(_ path: String, _ params: [String: String] = [:]) async throws -> JSON {
        let key = settings.tmdbKey
        var p = params
        var h: [String: String] = [:]
        // A v4 "read access token" is a long JWT; a v3 key is 32 hex characters.
        if key.count > 40 { h["Authorization"] = "Bearer \(key)" } else { p["api_key"] = key }
        return try await getJSON(PlexClient.url(tmdbBase, path, p.mapValues { $0 as Any? }), headers: h)
    }

    private func pick(_ list: [JSON], lang: String?) -> JSON? {
        let sorted = list.sorted { (($0["vote_average"] as? NSNumber)?.doubleValue ?? 0) > (($1["vote_average"] as? NSNumber)?.doubleValue ?? 0) }
        func code(_ j: JSON) -> String? { j["iso_639_1"] as? String }
        if let lang, let m = sorted.first(where: { code($0) == lang }) { return m }
        return sorted.first { code($0) == "en" } ?? sorted.first { code($0) == nil } ?? sorted.first
    }

    /// Logo, backdrop and poster for a movie or show; cached on the Apple TV.
    func artwork(_ item: PlexItem) async -> Artwork? {
        guard !settings.tmdbKey.isEmpty, settings.tmdbArtwork else { return nil }
        let kind = item.type == "show" ? "tv" : item.type == "movie" ? "movie" : nil
        guard let kind, let id = item.guids["tmdb"] else { return nil }
        let ck = kind + id
        if let a = artCache[ck] { return a }
        if let t = artPending[ck] { return await t.value }
        let task = Task<Artwork?, Never> {
            guard let r = try? await tmdb("/\(kind)/\(id)/images", ["include_image_language": "en,tr,null"]) else { return nil }
            let logos = r["logos"] as? [JSON] ?? [], backs = r["backdrops"] as? [JSON] ?? [], posters = r["posters"] as? [JSON] ?? []
            let textless = backs.filter { $0["iso_639_1"] == nil || $0["iso_639_1"] is NSNull }
            func path(_ j: JSON?, _ size: String) -> String? { (j?["file_path"] as? String).map { tmdbImages + size + $0 } }
            return Artwork(logo: path(pick(logos, lang: "en"), "w780"),
                           backdrop: path(pick(textless.isEmpty ? backs : textless, lang: nil), "w1280"),
                           poster: path(pick(posters, lang: "en"), "w342"))
        }
        artPending[ck] = task
        let a = await task.value
        artPending[ck] = nil
        if let a {
            artCache[ck] = a
            if artCache.count > 600, let k = artCache.keys.first { artCache[k] = nil }
            defaults.set(try? JSONEncoder().encode(artCache), forKey: "tmdbArt")
        }
        return a
    }

    // MARK: - Ratings

    struct Ratings: Codable, Equatable {
        var imdb: String?
        var rtCritic: String?
        var rtAudience: String?
        var metaCritic: String?
        var metaUser: String?
        var letterboxd: String?
        var tmdb: String?
        var isEmpty: Bool { [imdb, rtCritic, rtAudience, metaCritic, metaUser, letterboxd].allSatisfy { $0 == nil } }
    }

    /// Plex already carries IMDb and Rotten Tomatoes (critic and audience) for items matched by its own agent.
    func plexRatings(_ item: PlexItem) -> Ratings {
        var out = Ratings()
        for r in item.ratings {
            let img = r["image"] as? String ?? ""
            guard let v = (r["value"] as? NSNumber)?.doubleValue ?? (r["value"] as? String).flatMap(Double.init) else { continue }
            if img.hasPrefix("imdb:") { out.imdb = String(format: "%.1f", v) }
            else if img.range(of: #"^rottentomatoes://image\.rating\.(ripe|rotten)"#, options: .regularExpression) != nil { out.rtCritic = "\(Int((v * 10).rounded()))%" }
            else if img.range(of: #"^rottentomatoes://image\.rating\.(upright|spilled)"#, options: .regularExpression) != nil { out.rtAudience = "\(Int((v * 10).rounded()))%" }
            else if img.hasPrefix("themoviedb:") { out.tmdb = "\(Int((v * 10).rounded()))%" }
        }
        if out.imdb == nil, (item.audienceRatingImage ?? "").contains("imdb"), let a = item.audienceRating { out.imdb = String(format: "%.1f", a) }
        if out.rtCritic == nil, (item.ratingImage ?? "").contains("rottentomatoes"), let r = item.rating { out.rtCritic = "\(Int((r * 10).rounded()))%" }
        if out.rtAudience == nil, (item.audienceRatingImage ?? "").contains("rottentomatoes"), let a = item.audienceRating { out.rtAudience = "\(Int((a * 10).rounded()))%" }
        return out
    }

    private func slug(_ t: String) -> String {
        var s = t.lowercased().replacingOccurrences(of: "&", with: "and")
        s = s.replacingOccurrences(of: #"['’.:]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Best effort: a source that fails or changes its page is left out. OMDb (free key) gives IMDb, Rotten Tomatoes
    /// and the Metascore. Letterboxd and the Metacritic user score have no public API, so their public pages are read.
    func ratings(_ item: PlexItem) async -> Ratings {
        let ck = "ratings.\(item.ratingKey ?? "")"
        if let d = defaults.data(forKey: ck), let c = try? JSONDecoder().decode(CachedRatings.self, from: d),
           Date().timeIntervalSince1970 - c.at < 7 * 86400 { return c.r }
        var r = plexRatings(item)
        let ids = item.guids
        let isShow = item.type == "show"
        let omdbURL = (settings.omdbKey.isEmpty ? nil : ids["imdb"]).map {
            PlexClient.url("https://www.omdbapi.com", "/", ["i": $0, "apikey": settings.omdbKey])
        }
        let letterboxdURL = isShow ? nil : ids["tmdb"].flatMap { URL(string: "https://letterboxd.com/tmdb/\($0)/") }
        let metacriticURL = (item.type == "movie" || isShow) && !item.title.isEmpty
            ? URL(string: "https://www.metacritic.com/\(isShow ? "tv" : "movie")/\(slug(item.title))/") : nil
        async let omdb = optionalJSON(omdbURL)
        async let letterboxd = page(letterboxdURL)
        async let metacritic = page(metacriticURL)
        if let o = await omdb {
            if let v = o["imdbRating"] as? String, v != "N/A" { r.imdb = v }
            if let v = o["Metascore"] as? String, v != "N/A" { r.metaCritic = v }
            for x in o["Ratings"] as? [JSON] ?? [] where x["Source"] as? String == "Rotten Tomatoes" && r.rtCritic == nil {
                r.rtCritic = x["Value"] as? String
            }
        }
        if let page = await letterboxd, let v = firstMatch(#"name="twitter:data2" content="([\d.]+) out of 5""#, in: page), let n = Double(v) {
            r.letterboxd = String(format: "%.1f", n)
        }
        if let page = await metacritic {
            if let v = firstMatch(#""userScore"\s*:\s*\{[^}]*?"score"\s*:\s*([\d.]+)"#, in: page) ?? firstMatch(#"user score[^\d]{0,200}?(\d\.\d)"#, in: page),
               let n = Double(v) { r.metaUser = String(format: "%.1f", n) }
            if r.metaCritic == nil {
                r.metaCritic = firstMatch(#""criticScoreSummary"\s*:\s*\{[^}]*?"score"\s*:\s*(\d+)"#, in: page) ?? firstMatch(#""ratingValue"\s*:\s*"?(\d+)"#, in: page)
            }
        }
        defaults.set(try? JSONEncoder().encode(CachedRatings(at: Date().timeIntervalSince1970, r: r)), forKey: ck)
        return r
    }
    private struct CachedRatings: Codable { var at: Double; var r: Ratings }

    private func optionalJSON(_ url: URL?) async -> JSON? {
        guard let url else { return nil }
        return try? await getJSON(url)
    }

    private func page(_ url: URL?) async -> String? {
        guard let url, let d = try? await get(url, headers: ["User-Agent": "Mozilla/5.0 (AppleTV; tvOS) AppleWebKit/605.1.15"]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: - OpenSubtitles

    struct SubtitleResult: Identifiable {
        var id: String { "\(source):\(fileId)" }
        var source: String           // "opensubtitles" or "plex"
        var fileId: String
        var language: String
        var title: String
        var hashMatch = false
        var hearingImpaired = false
        var downloads = 0
        var machineTranslated = false
        var plexStream: PlexStream?
    }

    private var osToken: String?
    private var osHeaders: [String: String] {
        var h = ["Api-Key": settings.openSubtitlesKey, "Accept": "application/json", "X-User-Agent": appUA, "User-Agent": appUA]
        if let osToken { h["Authorization"] = "Bearer \(osToken)" }
        return h
    }

    /// Signing in raises the daily download limit; without an account the API key alone allows a few a day.
    private func osLogin() async {
        guard osToken == nil, !settings.openSubtitlesUser.isEmpty, !settings.openSubtitlesPassword.isEmpty else { return }
        let r = try? await getJSON(URL(string: osBase + "/login")!, headers: osHeaders, method: "POST",
                                   body: ["username": settings.openSubtitlesUser, "password": settings.openSubtitlesPassword])
        osToken = r?["token"] as? String
    }
    func resetLogin() { osToken = nil }

    /// OpenSubtitles hash: file size plus the first and last 64 KB summed as little-endian 64-bit words. Finds
    /// subtitles cut for this exact file, which is how Infuse gets well-synced results. Two range requests to Plex.
    func fileHash(_ url: URL, size: Int64) async -> String? {
        let chunk: Int64 = 65536
        guard size >= chunk * 2 else { return nil }
        func range(_ from: Int64) async -> Data? {
            try? await get(url, headers: ["Range": "bytes=\(from)-\(from + chunk - 1)"])
        }
        async let head = range(0)
        async let tail = range(size - chunk)
        guard let a = await head, let b = await tail, a.count >= chunk, b.count >= chunk else { return nil }
        var hash = UInt64(bitPattern: size)
        for buf in [a, b] {
            buf.prefix(Int(chunk)).withUnsafeBytes { raw in
                for i in stride(from: 0, to: Int(chunk), by: 8) {
                    hash = hash &+ UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    private func optionalHash(_ url: URL?, _ size: Int64?) async -> String? {
        guard let url, let size else { return nil }
        return await fileHash(url, size: size)
    }

    /// item: movie or episode; show: the episode's show (for its TMDB/IMDb id); langs: ["en", "tr"].
    func searchSubtitles(item: PlexItem, show: PlexItem?, languages: [String], fileURL: URL?, fileSize: Int64?) async throws -> [SubtitleResult] {
        guard !settings.openSubtitlesKey.isEmpty else { throw PlexError.message("No OpenSubtitles API key (Settings → Online services)") }
        async let hashTask = optionalHash(fileURL, fileSize)
        await osLogin()
        let hash = await hashTask
        var p: [String: String] = ["languages": languages.joined(separator: ","), "order_by": "download_count"]
        if let hash { p["moviehash"] = hash }
        if item.type == "episode" {
            let sid = (show ?? item).guids
            if let t = sid["tmdb"] { p["parent_tmdb_id"] = t } else if let i = sid["imdb"] { p["parent_imdb_id"] = i.replacingOccurrences(of: "tt", with: "") }
            else { p["query"] = item.grandparentTitle ?? item.title }
            p["season_number"] = item.parentIndex.map(String.init)
            p["episode_number"] = item.index.map(String.init)
        } else {
            let mid = item.guids
            if let t = mid["tmdb"] { p["tmdb_id"] = t } else if let i = mid["imdb"] { p["imdb_id"] = i.replacingOccurrences(of: "tt", with: "") }
            else { p["query"] = item.title; if let y = item.year { p["year"] = String(y) } }
        }
        let r = try await getJSON(PlexClient.url(osBase, "/subtitles", p.mapValues { $0 as Any? }), headers: osHeaders)
        let results: [SubtitleResult] = (r["data"] as? [JSON] ?? []).compactMap { d in
            let a = d["attributes"] as? JSON ?? [:]
            guard let f = (a["files"] as? [JSON])?.first, let fid = (f["file_id"] as? NSNumber)?.stringValue else { return nil }
            return SubtitleResult(source: "opensubtitles", fileId: fid, language: a["language"] as? String ?? "",
                                  title: (a["release"] as? String) ?? (f["file_name"] as? String) ?? "Subtitle",
                                  hashMatch: (a["moviehash_match"] as? Bool) ?? false,
                                  hearingImpaired: (a["hearing_impaired"] as? Bool) ?? false,
                                  downloads: (a["download_count"] as? NSNumber)?.intValue ?? 0,
                                  machineTranslated: ((a["ai_translated"] as? Bool) ?? false) || ((a["machine_translated"] as? Bool) ?? false))
        }
        return results.sorted { ($0.hashMatch ? 1 : 0, $0.downloads) > ($1.hashMatch ? 1 : 0, $1.downloads) }
    }

    private var subtitleDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cachedSubtitle(_ name: String) -> URL? {
        let u = subtitleDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Downloads one result to a local .srt file. Kept on the Apple TV so a replay doesn't use up the download quota.
    func download(_ result: SubtitleResult) async throws -> URL {
        let name = "os-\(result.fileId).srt"
        if let u = cachedSubtitle(name) { return u }
        await osLogin()
        let r = try await getJSON(URL(string: osBase + "/download")!, headers: osHeaders, method: "POST", body: ["file_id": Int(result.fileId) ?? 0, "sub_format": "srt"])
        guard let link = (r["link"] as? String).flatMap(URL.init(string:)) else { throw PlexError.message((r["message"] as? String) ?? "No download link") }
        let data = try await get(link)
        let u = subtitleDir.appendingPathComponent(name)
        try data.write(to: u, options: .atomic)
        // Keep the 40 most recent downloads.
        if let files = try? FileManager.default.contentsOfDirectory(at: subtitleDir, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 40 {
            let sorted = files.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for f in sorted.prefix(files.count - 40) { try? FileManager.default.removeItem(at: f) }
        }
        return u
    }
}
