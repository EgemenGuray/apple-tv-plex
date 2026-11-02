import Combine
import Foundation
import SwiftUI
#if !os(tvOS)
import UserNotifications
#endif

/// Holds the IPTV sources, what they provide, the guide, and the user's library tools (favourites, recents, hidden
/// and PIN-locked groups, renamed channels, reminders, resume points). Sources and guide are cached on disk and
/// refreshed in the background.
@MainActor
final class IPTVStore: ObservableObject {
    static let shared = IPTVStore()

    @Published private(set) var playlists: [IPTVPlaylist] = []
    @Published private(set) var contents: [UUID: IPTVContent] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var guideLoading = false
    @Published private(set) var guideUpdated: Date?
    @Published private(set) var guideVersion = 0

    /// Visible content: enabled sources, hidden groups removed, locked groups removed until unlocked, names applied.
    @Published private(set) var channels: [IPTVChannel] = []
    @Published private(set) var movies: [IPTVMovie] = []
    @Published private(set) var series: [IPTVSeries] = []

    @Published private(set) var favorites: [String] = []
    @Published private(set) var recents: [String] = []
    @Published private(set) var hiddenGroups: Set<String> = []
    @Published private(set) var lockedGroups: Set<String> = []
    @Published private(set) var renames: [String: String] = [:]
    @Published private(set) var reminders: [IPTVReminder] = []
    @Published private(set) var pin = ""
    @Published private(set) var unlocked = false
    @Published var dueReminder: IPTVReminder?
    /// Use IPTV without signing in to Plex.
    @Published var iptvOnly: Bool { didSet { d.set(iptvOnly, forKey: "iptv.only") } }

    /// Quality the player measured per channel.
    @Published private(set) var measured: [String: IPTVMeasured] = [:]
    private var nameTags: [String: Set<IPTVTag>] = [:]
    private var positions: [String: [Double]] = [:]
    /// What was being watched, for Continue Watching.
    @Published private(set) var resumeEntries: [IPTVResume] = []
    /// When each channel was tuned, for Trending Channels.
    private var plays: [String: [Double]] = [:]
    private var details: [String: IPTVDetails] = [:]
    private var epg: [String: [IPTVProgramme]] = [:]
    private var epgNames: [String: String] = [:]
    private var epgIcons: [String: String] = [:]
    private var epgKeyCache: [String: String?] = [:]
    private var channelByID: [String: IPTVChannel] = [:]
    private let d = UserDefaults.standard
    private var reminderTimer: Timer?

    private init() {
        iptvOnly = UserDefaults.standard.bool(forKey: "iptv.only")
        playlists = decode([IPTVPlaylist].self, "iptv.playlists") ?? []
        favorites = d.stringArray(forKey: "iptv.favorites") ?? []
        recents = d.stringArray(forKey: "iptv.recents") ?? []
        hiddenGroups = Set(d.stringArray(forKey: "iptv.hidden") ?? [])
        lockedGroups = Set(d.stringArray(forKey: "iptv.locked") ?? [])
        renames = (d.dictionary(forKey: "iptv.renames") as? [String: String]) ?? [:]
        reminders = decode([IPTVReminder].self, "iptv.reminders") ?? []
        pin = d.string(forKey: "iptv.pin") ?? ""
        positions = (d.dictionary(forKey: "iptv.positions") as? [String: [Double]]) ?? [:]
        measured = decode([String: IPTVMeasured].self, "iptv.measured") ?? [:]
        resumeEntries = decode([IPTVResume].self, "iptv.resume") ?? []
        plays = (d.dictionary(forKey: "iptv.plays") as? [String: [Double]]) ?? [:]
        for p in playlists { if let c = readCache(p.id) { contents[p.id] = c } }
        rebuild()
        if let g = readGuideCache() {
            epg = g.programmes
            epgNames = g.names
            epgIcons = g.icons ?? [:]
            guideUpdated = g.date
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in IPTVStore.shared.checkReminders() }
        }
        Task { await refreshIfStale() }
    }

    var hasSources: Bool { !playlists.isEmpty }
    func playlist(_ id: UUID) -> IPTVPlaylist? { playlists.first { $0.id == id } }
    func channel(_ id: String) -> IPTVChannel? { channelByID[id] }

    // MARK: - Sources

    func save(_ p: IPTVPlaylist) {
        var p = p
        if let i = playlists.firstIndex(where: { $0.id == p.id }) {
            playlists[i] = p
        } else {
            p.colorIndex = (playlists.map(\.colorIndex).max() ?? -1) + 1
            playlists.append(p)
        }
        persistPlaylists()
        Task { await refresh(p.id) }
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].enabled = on
        persistPlaylists()
        rebuild()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        contents[id] = nil
        errors[id] = nil
        try? FileManager.default.removeItem(at: cacheURL(id))
        persistPlaylists()
        rebuild()
    }

    func move(from: IndexSet, to: Int) {
        playlists.move(fromOffsets: from, toOffset: to)
        persistPlaylists()
        rebuild()
    }

    func refreshIfStale() async {
        let stale = playlists.filter { $0.enabled && ($0.lastRefresh.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true || contents[$0.id] == nil) }
        for p in stale { await refresh(p.id, guide: false) }
        if guideUpdated.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true || epg.isEmpty { await refreshGuide() }
    }

    func refreshAll() async {
        for p in playlists where p.enabled { await refresh(p.id, guide: false) }
        await refreshGuide()
    }

    func refresh(_ id: UUID, guide: Bool = true) async {
        guard let p = playlist(id), !loading.contains(id) else { return }
        loading.insert(id)
        errors[id] = nil
        defer { loading.remove(id) }
        do {
            let content: IPTVContent
            switch p.kind {
            case .xtream:
                content = try await XtreamClient(playlist: p).load(playlist: p, liveExtension: Platform.hasFFmpeg ? "ts" : "m3u8")
            case .m3u:
                let data = try await fetch(p.url, userAgent: p.userAgent)
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                guard text.contains("#EXTINF") || text.contains("#EXTM3U") else { throw IPTVError.message("This address didn't return an M3U playlist.") }
                content = await Task.detached(priority: .userInitiated) { M3UParser.parse(text, playlist: p) }.value
            }
            contents[id] = content
            writeCache(id, content)
            if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].lastRefresh = Date() }
            persistPlaylists()
            rebuild()
            if guide { await refreshGuide() }
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    private func fetch(_ address: String, userAgent: String) async throws -> Data {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw IPTVError.message("The address isn't valid.") }
        if url.isFileURL { return try Data(contentsOf: url) }
        var req = URLRequest(url: url, timeoutInterval: 90)
        if !userAgent.isEmpty { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw IPTVError.message("The server answered \(h.statusCode).") }
        return data
    }

    // MARK: - Guide

    func refreshGuide() async {
        guard !guideLoading else { return }
        var urls: [(String, String)] = []
        for p in playlists where p.enabled {
            let extra = p.epgURL.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for u in (contents[p.id]?.epgURLs ?? []) + extra where !u.isEmpty && !urls.contains(where: { $0.0 == u }) {
                urls.append((u, p.userAgent))
            }
        }
        guard !urls.isEmpty else { return }
        guideLoading = true
        defer { guideLoading = false }
        let all = contents.values.flatMap(\.channels)
        let ids = Set(all.compactMap { $0.epgID?.lowercased() })
        let names = Set(all.map { $0.name.iptvKey })
        let maxDays = max(1, all.compactMap { $0.catchup?.days }.max() ?? 1)
        let from = Date().addingTimeInterval(-Double(min(maxDays, 14)) * 86400)
        let to = Date().addingTimeInterval(4 * 86400)
        var merged: [String: [IPTVProgramme]] = [:]
        var mergedNames: [String: String] = [:]
        var mergedIcons: [String: String] = [:]
        for (u, ua) in urls {
            guard let data = try? await fetch(u, userAgent: ua), !data.isEmpty else { continue }
            let parsed = await Task.detached(priority: .utility) { () -> ([String: [IPTVProgramme]], [String: String], [String: String]) in
                let p = XMLTVParser.parse(data, wantedIDs: ids, wantedNames: names, from: from, to: to)
                return (p.programmes, p.names, p.icons)
            }.value
            for (k, v) in parsed.0 where merged[k] == nil { merged[k] = v }
            for (k, v) in parsed.1 where mergedNames[k] == nil { mergedNames[k] = v }
            for (k, v) in parsed.2 where mergedIcons[k] == nil { mergedIcons[k] = v }
        }
        guard !merged.isEmpty else { return }
        epg = merged
        epgNames = mergedNames
        epgIcons = mergedIcons
        epgKeyCache = [:]
        guideUpdated = Date()
        guideVersion += 1
        writeGuideCache(GuideCache(date: Date(), programmes: merged, names: mergedNames, icons: mergedIcons))
    }

    private func epgKey(_ ch: IPTVChannel) -> String? {
        if let k = epgKeyCache[ch.id] { return k }
        var key: String?
        if let id = ch.epgID?.lowercased(), epg[id] != nil { key = id }
        else if let id = epgNames[ch.name.iptvKey], epg[id] != nil { key = id }
        else if let orig = contents[ch.playlistID]?.channels.first(where: { $0.id == ch.id }), let id = epgNames[orig.name.iptvKey], epg[id] != nil { key = id }
        epgKeyCache[ch.id] = .some(key)
        return key
    }

    /// The playlist's logo, else the TV guide's icon for the channel.
    func logo(_ ch: IPTVChannel) -> String? {
        if let l = ch.logo, !l.isEmpty { return l }
        if let id = ch.epgID?.lowercased(), let i = epgIcons[id] { return i }
        return epgNames[ch.name.iptvKey].flatMap { epgIcons[$0] }
    }

    func programmes(_ ch: IPTVChannel) -> [IPTVProgramme] { epgKey(ch).flatMap { epg[$0] } ?? [] }

    func programmes(_ ch: IPTVChannel, from: Date, to: Date) -> [IPTVProgramme] {
        programmes(ch).filter { $0.end > from && $0.start < to }
    }

    func nowNext(_ ch: IPTVChannel, at date: Date = Date()) -> (IPTVProgramme?, IPTVProgramme?) {
        let list = programmes(ch)
        guard let i = list.firstIndex(where: { $0.end > date }) else { return (nil, nil) }
        if list[i].start <= date { return (list[i], list[safe: i + 1]) }
        return (nil, list[i])
    }

    var hasGuide: Bool { !epg.isEmpty }

    // MARK: - Groups

    func groups(_ kind: IPTVGroup.Kind, includeHidden: Bool = false) -> [IPTVGroup] {
        var out: [IPTVGroup] = []
        for p in playlists where p.enabled {
            guard let c = contents[p.id] else { continue }
            let names = kind == .live ? c.liveGroups : kind == .movie ? c.movieGroups : c.seriesGroups
            for n in names {
                let g = IPTVGroup(playlistID: p.id, kind: kind, name: n)
                if includeHidden || !hiddenGroups.contains(g.id) { out.append(g) }
            }
        }
        return out
    }

    func isHidden(_ g: IPTVGroup) -> Bool { hiddenGroups.contains(g.id) }
    func isLocked(_ g: IPTVGroup) -> Bool { lockedGroups.contains(g.id) }
    var needsUnlock: Bool { !unlocked && !lockedGroups.isEmpty }

    func setHidden(_ g: IPTVGroup, _ on: Bool) {
        if on { hiddenGroups.insert(g.id) } else { hiddenGroups.remove(g.id) }
        d.set(Array(hiddenGroups), forKey: "iptv.hidden")
        rebuild()
    }

    func setLocked(_ g: IPTVGroup, _ on: Bool) {
        if on { lockedGroups.insert(g.id) } else { lockedGroups.remove(g.id) }
        d.set(Array(lockedGroups), forKey: "iptv.locked")
        rebuild()
    }

    func setPIN(_ p: String) {
        pin = p
        d.set(p, forKey: "iptv.pin")
    }

    @discardableResult func unlock(_ attempt: String) -> Bool {
        guard attempt == pin else { return false }
        unlocked = true
        rebuild()
        return true
    }

    func lock() {
        unlocked = false
        rebuild()
    }

    func channels(in g: IPTVGroup) -> [IPTVChannel] { channels.filter { $0.playlistID == g.playlistID && $0.group == g.name } }
    func movies(in g: IPTVGroup) -> [IPTVMovie] { movies.filter { $0.playlistID == g.playlistID && $0.group == g.name } }
    func series(in g: IPTVGroup) -> [IPTVSeries] { series.filter { $0.playlistID == g.playlistID && $0.group == g.name } }

    private func rebuild() {
        var ch: [IPTVChannel] = []
        var mv: [IPTVMovie] = []
        var se: [IPTVSeries] = []
        for p in playlists where p.enabled {
            guard let c = contents[p.id] else { continue }
            func visible(_ k: IPTVGroup.Kind, _ g: String) -> Bool {
                let key = IPTVGroup.key(p.id, k, g)
                return !hiddenGroups.contains(key) && (unlocked || !lockedGroups.contains(key))
            }
            for var x in c.channels where visible(.live, x.group) {
                if let n = renames[x.id] { x.name = n }
                if x.userAgent == nil, !p.userAgent.isEmpty { x.userAgent = p.userAgent }
                ch.append(x)
            }
            mv += c.movies.filter { visible(.movie, $0.group) }
            se += c.series.filter { visible(.series, $0.group) }
        }
        channels = ch
        movies = mv
        series = se
        channelByID = Dictionary(ch.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tags: [String: Set<IPTVTag>] = [:]
        for c in ch { tags[c.id] = IPTVTag.parse(c.name + " " + c.group) }
        nameTags = tags
        epgKeyCache = [:]
    }

    // MARK: - Favourites, recents, names

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
        d.set(favorites, forKey: "iptv.favorites")
    }

    func moveFavorite(_ id: String, by delta: Int) {
        guard let i = favorites.firstIndex(of: id) else { return }
        let j = max(0, min(favorites.count - 1, i + delta))
        favorites.swapAt(i, j)
        d.set(favorites, forKey: "iptv.favorites")
    }

    var favoriteChannels: [IPTVChannel] { favorites.compactMap { channelByID[$0] } }
    var favoriteMovies: [IPTVMovie] { let s = Set(favorites); return movies.filter { s.contains($0.id) } }
    var favoriteSeries: [IPTVSeries] { let s = Set(favorites); return series.filter { s.contains($0.id) } }
    var recentChannels: [IPTVChannel] { recents.compactMap { channelByID[$0] } }

    func played(_ ch: IPTVChannel) {
        recents.removeAll { $0 == ch.id }
        recents.insert(ch.id, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        d.set(recents, forKey: "iptv.recents")
        let weekAgo = Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970
        plays[ch.id, default: []].append(Date().timeIntervalSince1970)
        for (k, v) in plays { let kept = v.filter { $0 > weekAgo }; plays[k] = kept.isEmpty ? nil : kept }
        d.set(plays, forKey: "iptv.plays")
    }

    /// Channels you tuned most in the last week.
    var trendingChannels: [IPTVChannel] {
        let since = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        return plays.map { ($0.key, $0.value.filter { $0 > since }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .compactMap { channelByID[$0.0] }
            .prefix(20).map { $0 }
    }

    func clearRecents() {
        recents = []
        d.set(recents, forKey: "iptv.recents")
    }

    func rename(_ ch: IPTVChannel, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        renames[ch.id] = t.isEmpty ? nil : t
        d.set(renames, forKey: "iptv.renames")
        rebuild()
    }

    func originalName(_ ch: IPTVChannel) -> String {
        contents[ch.playlistID]?.channels.first { $0.id == ch.id }?.name ?? ch.name
    }

    // MARK: - Quality

    /// Tags from the name, with the measured picture and sound replacing guesses once the channel has played.
    func tags(_ ch: IPTVChannel) -> Set<IPTVTag> {
        var t = nameTags[ch.id] ?? IPTVTag.parse(ch.name + " " + ch.group)
        if let m = measured[ch.id] {
            let mt = m.tags
            if mt.contains(where: \.isVideo) { t = t.filter { !$0.isVideo } }
            if mt.contains(.surround) || mt.contains(.stereo) { t.remove(.surround); t.remove(.stereo) }
            t.formUnion(mt)
        }
        return t
    }

    func recordMeasured(_ ch: IPTVChannel, height: Int, channels: Int?, hdr: Bool) {
        guard height > 0 else { return }
        let m = IPTVMeasured(height: height, channels: channels ?? measured[ch.id]?.channels, hdr: hdr)
        guard measured[ch.id] != m else { return }
        measured[ch.id] = m
        encode(measured, "iptv.measured")
    }

    // MARK: - Resume points

    func position(_ id: String) -> TimeInterval? { positions[id]?.first }
    func progress(_ id: String) -> Double? {
        guard let p = positions[id], p.count == 2, p[1] > 0 else { return nil }
        return p[0] / p[1]
    }

    func savePosition(_ id: String, _ t: TimeInterval, duration: TimeInterval) {
        guard duration > 0 else { return }
        if t < 30 || t > duration * 0.95 { positions[id] = nil } else { positions[id] = [t, duration] }
        d.set(positions, forKey: "iptv.positions")
        if let i = resumeEntries.firstIndex(where: { $0.id == id }) {
            if positions[id] == nil { resumeEntries.remove(at: i) } else { resumeEntries[i].updated = Date() }
            encode(resumeEntries, "iptv.resume")
        }
    }

    /// Films with a resume point.
    var continueWatching: [IPTVMovie] {
        movies.filter { positions[$0.id] != nil }
    }

    /// Records what is playing so Continue Watching can offer it again (films and episodes).
    func noteWatching(movie m: IPTVMovie) {
        upsertResume(IPTVResume(id: m.id, movieID: m.id, seriesID: nil, episode: nil, title: m.name, subtitle: m.year.map(String.init), poster: m.poster, updated: Date()))
    }

    func noteWatching(series s: IPTVSeries, episode e: IPTVEpisode) {
        // One entry per series: the latest episode replaces the earlier one.
        resumeEntries.removeAll { $0.seriesID == s.id && $0.id != e.id }
        upsertResume(IPTVResume(id: e.id, movieID: nil, seriesID: s.id, episode: e, title: s.name, subtitle: "\(e.label) · \(e.title)", poster: e.thumb ?? s.poster, updated: Date()))
    }

    private func upsertResume(_ r: IPTVResume) {
        resumeEntries.removeAll { $0.id == r.id }
        resumeEntries.insert(r, at: 0)
        if resumeEntries.count > 40 { resumeEntries.removeLast(resumeEntries.count - 40) }
        encode(resumeEntries, "iptv.resume")
    }

    func removeResume(_ id: String) {
        resumeEntries.removeAll { $0.id == id }
        positions[id] = nil
        d.set(positions, forKey: "iptv.positions")
        encode(resumeEntries, "iptv.resume")
    }

    /// Continue Watching rows that still exist in the enabled sources.
    var continueEntries: [IPTVResume] {
        let movieIDs = Set(movies.map(\.id))
        let seriesIDs = Set(series.map(\.id))
        return resumeEntries.filter { e in
            if let m = e.movieID { return movieIDs.contains(m) && positions[e.id] != nil }
            if let s = e.seriesID { return seriesIDs.contains(s) }
            return false
        }
    }

    func movie(_ id: String) -> IPTVMovie? { movies.first { $0.id == id } }
    func seriesItem(_ id: String) -> IPTVSeries? { series.first { $0.id == id } }

    // MARK: - Trending

    @Published private(set) var trendingMovies: [IPTVMovie] = []
    @Published private(set) var trendingSeries: [IPTVSeries] = []
    @Published private(set) var trendingFromTMDB = false
    private var trendingLoaded: Date?

    /// Films and series trending on TMDB this week that your sources have. Without a TMDB key: the best rated of
    /// the newest additions.
    func loadTrending(force: Bool = false) async {
        if !force, let t = trendingLoaded, Date().timeIntervalSince(t) < 3600, !trendingMovies.isEmpty || !trendingSeries.isEmpty { return }
        trendingLoaded = Date()
        async let tm = Online.shared.trending("movie")
        async let ts = Online.shared.trending("tv")
        let (tmdbMovies, tmdbSeries) = await (tm, ts)
        func match<T>(_ list: [T], _ name: (T) -> String, _ year: (T) -> Int?, _ wanted: [(title: String, year: Int?)]) -> [T] {
            var index: [String: [T]] = [:]
            for x in list { index[IPTVStore.cleanTitle(name(x)), default: []].append(x) }
            var out: [T] = []
            for w in wanted {
                guard let c = index[IPTVStore.cleanTitle(w.title)], !c.isEmpty else { continue }
                out.append(c.first { year($0) == w.year } ?? c[0])
            }
            return out
        }
        let m = match(movies, { $0.name }, { $0.year }, tmdbMovies)
        let s = match(series, { $0.name }, { $0.year }, tmdbSeries)
        trendingFromTMDB = !m.isEmpty || !s.isEmpty
        trendingMovies = m.isEmpty ? Array(movies.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }.prefix(300)
            .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(20)) : m
        trendingSeries = s.isEmpty ? Array(series.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(20)) : s
    }

    /// "EN - The Bear (2022) [4K]" → "thebear": drops language prefixes, years and tags.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        for p in [#"^\s*[\|\[]?[A-Z]{2,3}[\|\]]?\s*[-:|]\s*"#, #"^\s*\|[^|]+\|\s*"#, #"[\(\[][^\)\]]*[\)\]]"#, #"\b(19|20)\d{2}\b"#] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return s.iptvKey
    }

    // MARK: - Film and series details

    func details(movie m: IPTVMovie) async -> IPTVDetails? {
        if let d = details[m.id] { return d }
        guard let p = playlist(m.playlistID), p.kind == .xtream, let id = m.streamID else { return nil }
        let d = try? await XtreamClient(playlist: p).movieDetails(id)
        details[m.id] = d
        return d
    }

    func details(series s: IPTVSeries) async throws -> IPTVDetails {
        if let d = details[s.id] { return d }
        if let eps = s.episodes { return IPTVDetails(plot: s.plot, genre: s.genre, rating: s.rating, poster: s.poster, episodes: eps) }
        guard let p = playlist(s.playlistID), let id = s.seriesID else { throw IPTVError.message("This series has no episodes.") }
        let d = try await XtreamClient(playlist: p).seriesDetails(id)
        details[s.id] = d
        return d
    }

    // MARK: - Catch-up

    func catchupURL(_ ch: IPTVChannel, _ p: IPTVProgramme) -> String? {
        Catchup.url(channel: ch, programme: p, playlist: playlist(ch.playlistID), content: contents[ch.playlistID])
    }

    func canCatchUp(_ ch: IPTVChannel, _ p: IPTVProgramme) -> Bool {
        guard let c = ch.catchup, c.days > 0, p.start < Date() else { return false }
        return p.start > Date().addingTimeInterval(-Double(c.days) * 86400)
    }

    // MARK: - Reminders

    func hasReminder(_ ch: IPTVChannel, _ p: IPTVProgramme) -> Bool { reminders.contains { $0.channelID == ch.id && $0.start == p.start } }

    func toggleReminder(_ ch: IPTVChannel, _ p: IPTVProgramme) {
        let r = IPTVReminder(channelID: ch.id, channelName: ch.name, title: p.title, start: p.start)
        if let i = reminders.firstIndex(where: { $0.id == r.id }) {
            reminders.remove(at: i)
            #if !os(tvOS)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [r.id])
            #endif
        } else {
            reminders.append(r)
            scheduleNotification(r)
        }
        persistReminders()
    }

    private func scheduleNotification(_ r: IPTVReminder) {
        #if !os(tvOS)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = "Starts now on \(r.channelName)"
            content.sound = .default
            let secs = max(1, r.start.timeIntervalSinceNow - 60)
            let req = UNNotificationRequest(identifier: r.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false))
            center.add(req)
        }
        #endif
    }

    /// In the app (and on Apple TV, which has no notification banners) a due reminder shows as an alert.
    func checkReminders() {
        let now = Date()
        reminders.removeAll { $0.start < now.addingTimeInterval(-600) }
        if dueReminder == nil, let r = reminders.first(where: { $0.start <= now.addingTimeInterval(60) }) {
            reminders.removeAll { $0.id == r.id }
            dueReminder = r
        }
        persistReminders()
    }

    private func persistReminders() { encode(reminders, "iptv.reminders") }

    // MARK: - Search

    enum SearchScope: String, CaseIterable, Identifiable {
        case all, channels, programmes
        var id: String { rawValue }
        var label: String { ["all": "Everything", "channels": "Channel names", "programmes": "TV programmes"][rawValue]! }
    }

    struct SearchResults {
        var channels: [IPTVChannel] = []
        var programmes: [(IPTVChannel, IPTVProgramme)] = []
        var movies: [IPTVMovie] = []
        var series: [IPTVSeries] = []
        var isEmpty: Bool { channels.isEmpty && programmes.isEmpty && movies.isEmpty && series.isEmpty }
    }

    /// Channels, films and series by name, and guide programmes (live now or coming up) by title, category or
    /// description, which finds the channels showing a match or event.
    func search(_ q: String, tags: Set<IPTVTag> = [], scope: SearchScope = .all) -> SearchResults {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 || !tags.isEmpty else { return SearchResults() }
        var r = SearchResults()
        func match(_ s: String?) -> Bool { query.isEmpty || s?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let pool = tags.isEmpty ? channels : channels.filter { tags.isSubset(of: self.tags($0)) }
        if scope != .programmes { r.channels = Array(pool.filter { match($0.name) }.prefix(200)) }
        guard scope == .all || scope == .programmes else { return r }
        guard !query.isEmpty else { return r }
        if scope == .all {
            r.movies = Array(movies.filter { match($0.name) }.prefix(80))
            r.series = Array(series.filter { match($0.name) }.prefix(80))
        }
        let now = Date()
        var progs: [(IPTVChannel, IPTVProgramme)] = []
        var seenKeys = Set<String>()
        for ch in pool {
            guard let k = epgKey(ch), seenKeys.insert(k).inserted, let list = epg[k] else { continue }
            for p in list where p.end > now && p.start < now.addingTimeInterval(2 * 86400) && (match(p.title) || match(p.category) || match(p.episode)) {
                progs.append((ch, p))
            }
            if progs.count > 300 { break }
        }
        r.programmes = Array(progs.sorted { $0.1.start < $1.1.start }.prefix(80))
        return r
    }

    // MARK: - Persistence

    private func persistPlaylists() { encode(playlists, "iptv.playlists") }

    private func encode<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    private func decode<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }

    private var cacheDir: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iptv", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func cacheURL(_ id: UUID) -> URL { cacheDir.appendingPathComponent("\(id.uuidString).json") }

    private func readCache(_ id: UUID) -> IPTVContent? {
        (try? Data(contentsOf: cacheURL(id))).flatMap { try? JSONDecoder().decode(IPTVContent.self, from: $0) }
    }

    private func writeCache(_ id: UUID, _ c: IPTVContent) {
        let url = cacheURL(id)
        Task.detached(priority: .background) { if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) } }
    }

    private struct GuideCache: Codable {
        var date: Date
        var programmes: [String: [IPTVProgramme]]
        var names: [String: String]
        var icons: [String: String]?
    }

    private func readGuideCache() -> GuideCache? {
        (try? Data(contentsOf: cacheDir.appendingPathComponent("guide.json"))).flatMap { try? JSONDecoder().decode(GuideCache.self, from: $0) }
    }

    private func writeGuideCache(_ g: GuideCache) {
        let url = cacheDir.appendingPathComponent("guide.json")
        Task.detached(priority: .background) { if let data = try? JSONEncoder().encode(g) { try? data.write(to: url, options: .atomic) } }
    }
}
