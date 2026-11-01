import SwiftUI

// MARK: - Posters

struct IPTVPoster: View {
    let url: String?
    let title: String
    var subtitle: String?
    var progress: Double?
    var favorite = false
    var width: CGFloat = 240.s

    var body: some View {
        VStack(alignment: .leading, spacing: 8.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 12.s).fill(.white.opacity(0.06))
                Text(title).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(10.s)
                RemoteImage(url: url.flatMap { URL(string: $0) }, placeholder: .clear)
            }
            .frame(width: width, height: width * 1.5)
            .overlay(alignment: .bottom) { ProgressLine(progress: progress) }
            .overlay(alignment: .topTrailing) {
                if favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(10.s).shadow(radius: 4) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12.s, style: .continuous))
            Text(title).font(.caption).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width)
    }
}

private func posterGrid() -> [GridItem] {
    if Platform.isTV { return Array(repeating: GridItem(.fixed(240), spacing: 44), count: 6) }
    return [GridItem(.adaptive(minimum: Platform.isPhone ? 105 : 240.s, maximum: 260.s), spacing: 24.s, alignment: .top)]
}

/// Group picker, sort and grid shared by Movies and Series.
private struct GroupBar: View {
    let kind: IPTVGroup.Kind
    @Binding var groupKey: String
    @Binding var sort: String
    @ObservedObject private var store = IPTVStore.shared
    @State private var askPIN = false
    @State private var pending: String?

    var body: some View {
        let groups = store.groups(kind)
        HStack(spacing: 24.s) {
            Menu {
                Button("All") { groupKey = "all" }
                Button("Favorites") { groupKey = "favorites" }
                ForEach(groups) { g in
                    Button(g.name) {
                        if store.isLocked(g) && !store.unlocked { pending = g.id; askPIN = true } else { groupKey = g.id }
                    }
                }
            } label: {
                Label(groupKey == "all" ? "All" : groupKey == "favorites" ? "Favorites" : groups.first { $0.id == groupKey }?.name ?? "All",
                      systemImage: "line.3.horizontal.decrease.circle").lineLimit(1)
            }
            Menu {
                Button("Recently Added") { sort = "added" }
                Button("Name") { sort = "name" }
                Button("Rating") { sort = "rating" }
                Button("Year") { sort = "year" }
            } label: {
                Label(["added": "Recently Added", "name": "Name", "rating": "Rating", "year": "Year"][sort] ?? "Sort", systemImage: "arrow.up.arrow.down")
            }
            Spacer()
        }
        .padding(.horizontal, Platform.isPhone ? 12 : 60.s)
        .tvFocusSection()
        .pinPrompt($askPIN) { if let p = pending { groupKey = p } }
    }
}

// MARK: - Movies

struct MoviesView: View {
    @ObservedObject private var store = IPTVStore.shared
    @AppStorage("iptv.movieGroup") private var groupKey = "all"
    @AppStorage("iptv.movieSort") private var sort = "added"

    private var movies: [IPTVMovie] {
        var list: [IPTVMovie]
        switch groupKey {
        case "all": list = store.movies
        case "favorites": list = store.favoriteMovies
        default: list = store.groups(.movie).first { $0.id == groupKey }.map { store.movies(in: $0) } ?? store.movies
        }
        switch sort {
        case "name": list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "rating": list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case "year": list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        default: list.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10.s) {
            GroupBar(kind: .movie, groupKey: $groupKey, sort: $sort)
            ScrollView {
                let resume = store.continueWatching
                if groupKey == "all", !resume.isEmpty {
                    VStack(alignment: .leading, spacing: 12.s) {
                        Text("Continue Watching").font(.title3.bold()).padding(.horizontal, 60.s)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 40.s) {
                                ForEach(resume) { m in movieLink(m) }
                            }
                            .padding(.horizontal, 60.s).padding(.vertical, 24.s)
                        }
                        .scrollClipDisabled()
                    }
                    .tvFocusSection()
                }
                let list = movies
                if list.isEmpty {
                    Text(store.loading.isEmpty ? "No movies." : "Loading…").foregroundStyle(.secondary).padding(60.s)
                }
                LazyVGrid(columns: posterGrid(), spacing: 50.s) {
                    ForEach(list) { m in movieLink(m) }
                }
                .padding(.horizontal, Platform.isPhone ? 12 : 60.s).padding(.vertical, 30.s)
            }
            .scrollClipDisabled()
        }
    }

    private func movieLink(_ m: IPTVMovie) -> some View {
        NavigationLink(value: IPTVRoute.movie(m)) {
            IPTVPoster(url: m.poster, title: m.name, subtitle: [m.year.map(String.init), m.rating.map { String(format: "★ %.1f", $0) }].compactMap { $0 }.joined(separator: "  "),
                       progress: store.progress(m.id), favorite: store.isFavorite(m.id))
        }
        .buttonStyle(LiftButtonStyle())
        .contextMenu {
            Button(store.isFavorite(m.id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(m.id) }
            Button("Download") { IPTVRecorder.shared.download(movie: m) }
        }
    }
}

struct IPTVMovieDetail: View {
    let movie: IPTVMovie
    @ObservedObject private var store = IPTVStore.shared
    @State private var details: IPTVDetails?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: (details?.backdrop ?? movie.poster).flatMap { URL(string: $0) })
                .blur(radius: details?.backdrop == nil ? 30 : 0)
                .overlay(LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 60.s) { poster; info }
                    VStack(alignment: .leading, spacing: 30.s) { poster; info }
                }
                .padding(Platform.isPhone ? 16 : 80.s)
            }
        }
        .task { details = await store.details(movie: movie) }
    }

    private var poster: some View {
        IPTVPoster(url: details?.poster ?? movie.poster, title: movie.name, width: Platform.isPhone ? 160 : 400.s)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 24.s) {
            Text(movie.name).font(.largeTitle.bold())
            HStack(spacing: 20.s) {
                if let y = movie.year { Text(String(y)) }
                if let d = details?.duration, d > 0 { Text(IPTVFormat.minutes(d)) }
                if let r = details?.rating ?? movie.rating { Label(String(format: "%.1f", r), systemImage: "star.fill") }
                if let g = details?.genre { Text(g).lineLimit(1) }
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 30.s) {
                Button {
                    IPTVPlayerPresenter.shared.movie(movie)
                } label: {
                    Label(store.position(movie.id) != nil ? "Resume" : "Play", systemImage: "play.fill").padding(.horizontal, 20.s)
                }
                .buttonStyle(.borderedProminent)
                if store.position(movie.id) != nil {
                    Button("Play from Start") {
                        store.savePosition(movie.id, 0, duration: 1)
                        IPTVPlayerPresenter.shared.movie(movie)
                    }
                }
                Button { store.toggleFavorite(movie.id) } label: {
                    Image(systemName: store.isFavorite(movie.id) ? "star.fill" : "star")
                }
                Button { IPTVRecorder.shared.download(movie: movie) } label: { Image(systemName: "arrow.down.circle") }
            }
            .tvFocusSection()
            if let plot = details?.plot ?? movie.plot { Text(plot).font(.body).frame(maxWidth: 1100.s, alignment: .leading) }
            if let c = details?.cast { LabeledText(label: "Cast", text: c) }
            if let d = details?.director { LabeledText(label: "Director", text: d) }
        }
    }
}

struct LabeledText: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6.s) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(3)
        }
        .frame(maxWidth: 1100.s, alignment: .leading)
    }
}

// MARK: - Series

struct SeriesView: View {
    @ObservedObject private var store = IPTVStore.shared
    @AppStorage("iptv.seriesGroup") private var groupKey = "all"
    @AppStorage("iptv.seriesSort") private var sort = "added"

    private var list: [IPTVSeries] {
        var l: [IPTVSeries]
        switch groupKey {
        case "all": l = store.series
        case "favorites": l = store.favoriteSeries
        default: l = store.groups(.series).first { $0.id == groupKey }.map { store.series(in: $0) } ?? store.series
        }
        switch sort {
        case "name": l.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "rating": l.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case "year": l.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        default: break
        }
        return l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10.s) {
            GroupBar(kind: .series, groupKey: $groupKey, sort: $sort)
            ScrollView {
                let l = list
                if l.isEmpty { Text(store.loading.isEmpty ? "No series." : "Loading…").foregroundStyle(.secondary).padding(60.s) }
                LazyVGrid(columns: posterGrid(), spacing: 50.s) {
                    ForEach(l) { s in seriesLink(s) }
                }
                .padding(.horizontal, Platform.isPhone ? 12 : 60.s).padding(.vertical, 30.s)
            }
            .scrollClipDisabled()
        }
    }

    private func seriesLink(_ s: IPTVSeries) -> some View {
        NavigationLink(value: IPTVRoute.series(s)) {
            IPTVPoster(url: s.poster, title: s.name, subtitle: s.year.map(String.init), favorite: store.isFavorite(s.id))
        }
        .buttonStyle(LiftButtonStyle())
        .contextMenu {
            Button(store.isFavorite(s.id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(s.id) }
        }
    }
}

struct IPTVSeriesDetail: View {
    let series: IPTVSeries
    @ObservedObject private var store = IPTVStore.shared
    @State private var details: IPTVDetails?
    @State private var error: String?
    @State private var season = 0

    private var seasons: [Int] { Array(Set((details?.episodes ?? []).map(\.season))).sorted() }
    private var episodes: [IPTVEpisode] { (details?.episodes ?? []).filter { $0.season == season } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: (details?.backdrop ?? series.poster).flatMap { URL(string: $0) })
                .blur(radius: details?.backdrop == nil ? 30 : 0)
                .overlay(LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 30.s) {
                    HStack(alignment: .top, spacing: 50.s) {
                        if !Platform.isPhone { IPTVPoster(url: details?.poster ?? series.poster, title: series.name, width: 300.s) }
                        VStack(alignment: .leading, spacing: 20.s) {
                            Text(series.name).font(.largeTitle.bold())
                            HStack(spacing: 20.s) {
                                if let y = series.year { Text(String(y)) }
                                if let r = details?.rating ?? series.rating { Label(String(format: "%.1f", r), systemImage: "star.fill") }
                                if let g = details?.genre ?? series.genre { Text(g).lineLimit(1) }
                            }
                            .font(.callout).foregroundStyle(.secondary)
                            HStack(spacing: 30.s) {
                                if let first = resumeEpisode {
                                    Button {
                                        IPTVPlayerPresenter.shared.episode(series, first, all: details?.episodes ?? [])
                                    } label: {
                                        Label(store.position(first.id) != nil ? "Resume \(first.label)" : "Play \(first.label)", systemImage: "play.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                Button { store.toggleFavorite(series.id) } label: { Image(systemName: store.isFavorite(series.id) ? "star.fill" : "star") }
                                if !episodes.isEmpty {
                                    Button { episodes.forEach { IPTVRecorder.shared.download(episode: $0, of: series) } } label: {
                                        Label("Download Season", systemImage: "arrow.down.circle")
                                    }
                                }
                            }
                            .tvFocusSection()
                            if let p = details?.plot ?? series.plot { Text(p).font(.callout).lineLimit(5).frame(maxWidth: 1100.s, alignment: .leading) }
                            if let c = details?.cast { LabeledText(label: "Cast", text: c) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    if details == nil && error == nil { ProgressView() }
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16.s) {
                                ForEach(seasons, id: \.self) { s in
                                    Button { season = s } label: { Text("Season \(s)").padding(.horizontal, 22.s).padding(.vertical, 10.s) }
                                        .buttonStyle(PillStyle(selected: s == season))
                                }
                            }
                            .padding(.vertical, 10.s)
                        }
                        .scrollClipDisabled()
                        .tvFocusSection()
                    }
                    LazyVStack(alignment: .leading, spacing: 10.s) {
                        ForEach(episodes) { e in episodeRow(e) }
                    }
                }
                .padding(Platform.isPhone ? 16 : 80.s)
            }
        }
        .task {
            do {
                let d = try await store.details(series: series)
                details = d
                season = resumeEpisode?.season ?? d.episodes.first?.season ?? 1
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The episode in progress, else the first one not finished.
    private var resumeEpisode: IPTVEpisode? {
        let all = details?.episodes ?? []
        return all.first { store.position($0.id) != nil } ?? all.first
    }

    private func episodeRow(_ e: IPTVEpisode) -> some View {
        Button {
            IPTVPlayerPresenter.shared.episode(series, e, all: details?.episodes ?? [])
        } label: {
            HStack(alignment: .top, spacing: 24.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10.s).fill(.white.opacity(0.06))
                    RemoteImage(url: (e.thumb ?? series.poster).flatMap { URL(string: $0) }, placeholder: .clear)
                }
                .frame(width: Platform.isPhone ? 120 : 320.s, height: Platform.isPhone ? 68 : 180.s)
                .overlay(alignment: .bottom) { ProgressLine(progress: store.progress(e.id)) }
                .clipShape(RoundedRectangle(cornerRadius: 10.s))
                VStack(alignment: .leading, spacing: 8.s) {
                    Text("\(e.number). \(e.title)").font(.headline).lineLimit(1)
                    if let d = e.duration, d > 0 { Text(IPTVFormat.minutes(d)).font(.caption).foregroundStyle(.secondary) }
                    if let p = e.plot { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                Spacer(minLength: 0)
            }
            .padding(12.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
        .contextMenu {
            Button("Download") { IPTVRecorder.shared.download(episode: e, of: series) }
        }
    }
}

// MARK: - Favorites

struct IPTVFavoritesView: View {
    @ObservedObject private var store = IPTVStore.shared
    @AppStorage("iptv.favTab") private var tab = "live"
    @State private var focused: IPTVChannel?

    var body: some View {
        VStack(alignment: .leading, spacing: 16.s) {
            HStack(spacing: 16.s) {
                ForEach([("live", "Live TV"), ("movies", "Movies"), ("series", "Series")], id: \.0) { key, title in
                    Button { tab = key } label: { Text(title).padding(.horizontal, 26.s).padding(.vertical, 10.s) }
                        .buttonStyle(PillStyle(selected: tab == key))
                }
            }
            .padding(.horizontal, 60.s)
            .tvFocusSection()
            switch tab {
            case "movies":
                grid(store.favoriteMovies.map { ($0.id, IPTVRoute.movie($0), $0.poster, $0.name) })
            case "series":
                grid(store.favoriteSeries.map { ($0.id, IPTVRoute.series($0), $0.poster, $0.name) })
            default:
                if store.favoriteChannels.isEmpty {
                    empty("Long-press a channel and choose Add to Favorites.")
                } else {
                    ChannelList(channels: store.favoriteChannels, focused: $focused)
                }
            }
        }
    }

    @ViewBuilder private func grid(_ items: [(String, IPTVRoute, String?, String)]) -> some View {
        if items.isEmpty {
            empty("Long-press a poster and choose Add to Favorites.")
        } else {
            ScrollView {
                LazyVGrid(columns: posterGrid(), spacing: 50.s) {
                    ForEach(items, id: \.0) { id, route, poster, name in
                        NavigationLink(value: route) { IPTVPoster(url: poster, title: name, progress: store.progress(id)) }
                            .buttonStyle(LiftButtonStyle())
                            .contextMenu { Button("Remove from Favorites") { store.toggleFavorite(id) } }
                    }
                }
                .padding(.horizontal, 60.s).padding(.vertical, 30.s)
            }
            .scrollClipDisabled()
        }
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 16.s) {
            Image(systemName: "star").font(.system(size: 60.s))
            Text("No favorites yet").font(.headline)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search

/// Search channel names and TV programmes, filtered by quality, plus movies and series.
struct IPTVSearchView: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var query = ""
    @State private var scope: IPTVStore.SearchScope = .all
    @State private var tags: Set<IPTVTag> = []
    @State private var results = IPTVStore.SearchResults()
    @State private var picked: GuideView.Picked?

    var body: some View {
        VStack(alignment: .leading, spacing: 16.s) {
            TextField("Channels, programmes, movies, series", text: $query)
                .searchFieldStyle()
                .frame(maxWidth: 1200.s)
                .padding(.horizontal, 60.s)
                .autocorrectionDisabled()
            Picker("Search in", selection: $scope) {
                ForEach(IPTVStore.SearchScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 1000.s)
            .padding(.horizontal, 60.s)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12.s) {
                    ForEach(IPTVTag.allCases) { t in
                        Button {
                            if tags.contains(t) { tags.remove(t) } else { tags.insert(t) }
                        } label: { Text(t.rawValue).font(.caption.bold()).padding(.horizontal, 18.s).padding(.vertical, 6.s) }
                        .buttonStyle(PillStyle(selected: tags.contains(t)))
                    }
                }
                .padding(.horizontal, 60.s).padding(.vertical, 6.s)
            }
            .tvFocusSection()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30.s) {
                    if !results.channels.isEmpty {
                        section("Channels")
                        ForEach(results.channels) { ch in
                            ChannelRow(channel: ch, now: Date()) { IPTVPlayerPresenter.shared.live(ch, lineup: results.channels) }
                        }
                    }
                    if !results.programmes.isEmpty {
                        section("On TV")
                        ForEach(results.programmes, id: \.1.id) { ch, p in programmeRow(ch, p) }
                    }
                    if !results.movies.isEmpty {
                        section("Movies")
                        posterRow(results.movies.map { ($0.id, IPTVRoute.movie($0), $0.poster, $0.name, $0.playlistID) })
                    }
                    if !results.series.isEmpty {
                        section("Series")
                        posterRow(results.series.map { ($0.id, IPTVRoute.series($0), $0.poster, $0.name, $0.playlistID) })
                    }
                    if results.isEmpty && (query.count >= 2 || !tags.isEmpty) {
                        Text("No results").foregroundStyle(.secondary).padding(60.s)
                    }
                }
                .padding(.horizontal, 60.s).padding(.bottom, 60.s)
            }
        }
        .task(id: "\(query)|\(scope.rawValue)|\(tags.map(\.rawValue).sorted())|\(store.guideVersion)") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { results = store.search(query, tags: tags, scope: scope) }
        }
        .confirmationDialog(picked?.programme.title ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { pk in
            if pk.programme.isAiring() {
                Button("Watch Live") { IPTVPlayerPresenter.shared.live(pk.channel, lineup: results.channels.isEmpty ? [pk.channel] : results.channels) }
                if store.canCatchUp(pk.channel, pk.programme) { Button("Watch from the Start") { IPTVPlayerPresenter.shared.catchup(pk.channel, pk.programme) } }
            } else {
                Button(store.hasReminder(pk.channel, pk.programme) ? "Cancel Reminder" : "Remind Me") { store.toggleReminder(pk.channel, pk.programme) }
            }
            Button("Record") { IPTVRecorder.shared.record(pk.channel, programme: pk.programme) }
            Button("Cancel", role: .cancel) {}
        } message: { pk in
            Text("\(pk.channel.name) · \(IPTVFormat.day(pk.programme.start)) \(pk.programme.timeRange)")
        }
    }

    private func section(_ t: String) -> some View { Text(t).font(.title3.bold()).padding(.top, 10.s) }

    private func programmeRow(_ ch: IPTVChannel, _ p: IPTVProgramme) -> some View {
        Button { picked = GuideView.Picked(channel: ch, programme: p) } label: {
            HStack(spacing: 20.s) {
                VStack(alignment: .leading) {
                    Text(p.isAiring() ? "Now" : IPTVFormat.day(p.start)).font(.caption.bold()).foregroundStyle(p.isAiring() ? .red : .secondary)
                    Text(IPTVFormat.time(p.start)).font(.callout.monospacedDigit())
                }
                .frame(width: 150.s, alignment: .leading)
                ChannelLogo(channel: ch, size: 56.s)
                VStack(alignment: .leading, spacing: 4.s) {
                    Text(p.title).font(.callout.bold()).lineLimit(1)
                    HStack(spacing: 8.s) {
                        if store.playlists.count > 1 { SourceDot(playlistID: ch.playlistID) }
                        Text([ch.name, p.category].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ForEach(store.tags(ch).sorted { $0.rawValue < $1.rawValue }) { QualityBadge(tag: $0) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
    }

    private func posterRow(_ items: [(String, IPTVRoute, String?, String, UUID)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 40.s) {
                ForEach(items, id: \.0) { _, route, poster, name, pid in
                    NavigationLink(value: route) {
                        IPTVPoster(url: poster, title: name, width: 200.s).overlay(alignment: .topLeading) { SourceDot(playlistID: pid).padding(10.s) }
                    }
                    .buttonStyle(LiftButtonStyle())
                }
            }
            .padding(.vertical, 24.s)
        }
        .scrollClipDisabled()
        .tvFocusSection()
    }
}

extension View {
    @ViewBuilder func searchFieldStyle() -> some View {
        #if os(tvOS)
        self
        #else
        textFieldStyle(.roundedBorder)
        #endif
    }
}
