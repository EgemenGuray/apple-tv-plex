import Foundation

/// Reads M3U/M3U8 playlists (`#EXTM3U` with `#EXTINF` attributes). Live channels, films and series are told apart
/// by `tvg-type`, by the `/movie/` and `/series/` paths Xtream-style servers use, or by the file extension.
enum M3UParser {
    static func parse(_ text: String, playlist: IPTVPlaylist) -> IPTVContent {
        var content = IPTVContent()
        var headerCatchup: IPTVCatchup?
        var pending: [String: String] = [:]
        var pendingName = ""
        var pendingGroup: String?
        var pendingUA: String?
        var haveInfo = false
        var liveGroups = OrderedSet()
        var movieGroups = OrderedSet()
        var seriesGroups = OrderedSet()
        var seriesMap: [String: Int] = [:]
        var seen = Set<String>()
        let pid = playlist.id

        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") {
                let attrs = attributes(in: String(line.dropFirst(7)))
                for k in ["url-tvg", "x-tvg-url", "tvg-url"] {
                    if let v = attrs[k] { content.epgURLs += v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                }
                if let mode = attrs["catchup"] ?? attrs["catchup-type"] {
                    headerCatchup = IPTVCatchup(mode: mode, days: Int(attrs["catchup-days"] ?? "") ?? 7, source: attrs["catchup-source"])
                }
                continue
            }
            if line.hasPrefix("#EXTINF") {
                let body = line.drop { $0 != ":" }.dropFirst()
                let (attrPart, name) = splitInfo(String(body))
                pending = attributes(in: attrPart)
                pendingName = name.trimmingCharacters(in: .whitespaces)
                haveInfo = true
                continue
            }
            if line.hasPrefix("#EXTGRP:") { pendingGroup = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("#EXTVLCOPT:") {
                let opt = line.dropFirst(11)
                if opt.lowercased().hasPrefix("http-user-agent=") { pendingUA = String(opt.dropFirst(16)) }
                continue
            }
            if line.hasPrefix("#") { continue }

            // A stream address.
            let url = line
            let name = pendingName.isEmpty ? (pending["tvg-name"] ?? url) : pendingName
            let group = pending["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? pendingGroup ?? "Other"
            let logo = pending["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }
            let type = (pending["tvg-type"] ?? pending["type"] ?? "").lowercased()
            let kind = classify(url: url, name: name, type: type)
            defer { pending = [:]; pendingName = ""; pendingGroup = nil; pendingUA = nil; haveInfo = false }
            _ = haveInfo

            switch kind {
            case .live:
                var id = "\(pid.uuidString)|\(pending["tvg-id"] ?? "")|\(name)"
                if !seen.insert(id).inserted { id += "|\(url.hashValue)" }
                var catchup: IPTVCatchup?
                if let mode = pending["catchup"] ?? pending["catchup-type"] {
                    catchup = IPTVCatchup(mode: mode, days: Int(pending["catchup-days"] ?? "") ?? headerCatchup?.days ?? 7,
                                          source: pending["catchup-source"] ?? headerCatchup?.source)
                } else if let days = Int(pending["timeshift"] ?? pending["tvg-rec"] ?? pending["catchup-days"] ?? ""), days > 0 {
                    catchup = IPTVCatchup(mode: headerCatchup?.mode ?? "default", days: days, source: pending["catchup-source"] ?? headerCatchup?.source)
                } else if let h = headerCatchup {
                    catchup = h
                }
                if catchup != nil, catchup?.source == nil, catchup?.mode == "default" {
                    // "default" without a template: Xtream-style servers use their timeshift path.
                    if url.contains("/live/") || url.split(separator: "/").count >= 6 { catchup?.mode = "xc" }
                }
                let ch = IPTVChannel(id: id, playlistID: pid, name: name,
                                     number: Int(pending["tvg-chno"] ?? pending["channel-number"] ?? pending["tvg-num"] ?? ""),
                                     logo: logo, group: group, url: url,
                                     epgID: pending["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
                                     catchup: catchup, userAgent: pendingUA ?? pending["user-agent"] ?? pending["http-user-agent"],
                                     streamID: nil)
                content.channels.append(ch)
                liveGroups.insert(group)
            case .movie:
                let (title, year) = splitYear(name)
                content.movies.append(IPTVMovie(id: "\(pid.uuidString)|m|\(name)|\(url.hashValue)", playlistID: pid, name: title, poster: logo,
                                                group: group, url: url, rating: nil, year: year, added: nil, streamID: nil, plot: nil))
                movieGroups.insert(group)
            case .series:
                let ep = episodeInfo(name)
                let showName = ep?.show ?? name
                let key = "\(group)|\(showName.lowercased())"
                let episode = IPTVEpisode(id: "\(pid.uuidString)|e|\(url.hashValue)", season: ep?.season ?? 1, number: ep?.episode ?? 1,
                                          title: ep?.title ?? name, url: url, plot: nil, thumb: logo, duration: nil)
                if let i = seriesMap[key] {
                    content.series[i].episodes?.append(episode)
                } else {
                    seriesMap[key] = content.series.count
                    content.series.append(IPTVSeries(id: "\(pid.uuidString)|s|\(key)", playlistID: pid, name: showName, poster: logo, group: group,
                                                     plot: nil, rating: nil, year: nil, genre: nil, seriesID: nil, episodes: [episode]))
                }
                seriesGroups.insert(group)
            }
        }
        for i in content.series.indices {
            content.series[i].episodes?.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        }
        content.liveGroups = liveGroups.items
        content.movieGroups = movieGroups.items
        content.seriesGroups = seriesGroups.items
        return content
    }

    enum Kind { case live, movie, series }

    static func classify(url: String, name: String, type: String) -> Kind {
        if type == "movie" || type == "movies" || type == "vod" { return .movie }
        if type == "series" || type == "tvshow" { return .series }
        if type == "live" || type == "stream" { return .live }
        let lower = url.lowercased()
        if lower.contains("/series/") { return .series }
        if lower.contains("/movie/") || lower.contains("/movies/") { return .movie }
        let path = lower.split(separator: "?").first.map(String.init) ?? lower
        let ext = (path as NSString).pathExtension
        if ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "webm"].contains(ext) {
            return episodeInfo(name) != nil ? .series : .movie
        }
        return .live
    }

    /// Splits `#EXTINF:-1 key="v" key2="v, with comma",Name` into the attribute part and the name.
    static func splitInfo(_ s: String) -> (String, String) {
        var inQuote = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "\"" { inQuote.toggle() }
            else if c == ",", !inQuote { return (String(s[..<idx]), String(s[s.index(after: idx)...])) }
            idx = s.index(after: idx)
        }
        return (s, "")
    }

    /// key="value" and key=value pairs.
    static func attributes(in s: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=", chars[i] != " " { key.append(chars[i]); i += 1 }
            guard i < chars.count, chars[i] == "=" else { i += 1; continue }
            i += 1
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                i += 1
            } else {
                while i < chars.count, chars[i] != " " { value.append(chars[i]); i += 1 }
            }
            if !key.isEmpty { out[key.lowercased()] = value }
        }
        return out
    }

    struct EpisodeInfo { let show: String; let season: Int; let episode: Int; let title: String }

    /// "Show Name S01 E02", "Show.Name.S01E02.Title", "Show Name 1x02".
    static func episodeInfo(_ name: String) -> EpisodeInfo? {
        let patterns = [#"^(.*?)[\s._\-]*[Ss](\d{1,2})[\s._\-]*[Ee](\d{1,3})(.*)$"#, #"^(.*?)[\s._\-]+(\d{1,2})x(\d{1,3})(.*)$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), m.numberOfRanges >= 5,
                  let r1 = Range(m.range(at: 1), in: name), let r2 = Range(m.range(at: 2), in: name),
                  let r3 = Range(m.range(at: 3), in: name), let r4 = Range(m.range(at: 4), in: name) else { continue }
            let show = name[r1].replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -_|"))
            guard !show.isEmpty, let s = Int(name[r2]), let e = Int(name[r3]) else { continue }
            let rest = name[r4].replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -_|"))
            return EpisodeInfo(show: show, season: s, episode: e, title: rest.isEmpty ? "Episode \(e)" : rest)
        }
        return nil
    }

    /// "Title (2021)" or "Title - 2021" → ("Title", 2021).
    static func splitYear(_ name: String) -> (String, Int?) {
        guard let re = try? NSRegularExpression(pattern: #"^(.*?)[\s\-]*[\(\[]?((?:19|20)\d{2})[\)\]]?\s*$"#),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r1 = Range(m.range(at: 1), in: name), let r2 = Range(m.range(at: 2), in: name) else { return (name, nil) }
        let title = String(name[r1]).trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? name : title, Int(name[r2]))
    }
}

/// Insertion-ordered unique strings.
struct OrderedSet {
    private(set) var items: [String] = []
    private var set = Set<String>()
    mutating func insert(_ s: String) { if set.insert(s).inserted { items.append(s) } }
}
