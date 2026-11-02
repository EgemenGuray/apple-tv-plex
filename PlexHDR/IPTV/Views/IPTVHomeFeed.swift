import SwiftUI

/// IPTV home: Continue Watching, recently watched channels, trending channels, movies and series.
struct IPTVHomeFeed: View {
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var presenter = IPTVPlayerPresenter.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40.s) {
                let resume = store.continueEntries
                if !resume.isEmpty {
                    shelf("Continue Watching") {
                        ForEach(resume) { r in resumeCard(r) }
                    }
                }
                let recent = store.recentChannels
                if !recent.isEmpty {
                    shelf("Recently Watched Channels") {
                        ForEach(recent.prefix(20)) { ch in channelCard(ch, lineup: recent) }
                    }
                }
                let trending = store.trendingChannels
                if !trending.isEmpty {
                    shelf("Trending Channels", note: "Most watched in Lumen this week") {
                        ForEach(trending) { ch in channelCard(ch, lineup: trending) }
                    }
                }
                let favs = store.favoriteChannels
                if !favs.isEmpty {
                    shelf("Favorite Channels") {
                        ForEach(favs.prefix(30)) { ch in channelCard(ch, lineup: favs) }
                    }
                }
                if !store.trendingMovies.isEmpty {
                    shelf("Trending Movies", note: store.trendingFromTMDB ? "Trending on TMDB this week" : "Top rated new additions (add a TMDB key in Settings for real trends)") {
                        ForEach(store.trendingMovies) { m in
                            NavigationLink(value: IPTVRoute.movie(m)) {
                                IPTVPoster(url: m.poster, title: m.name, subtitle: m.year.map(String.init), progress: store.progress(m.id), favorite: store.isFavorite(m.id), width: 220.s)
                            }
                            .buttonStyle(LiftButtonStyle())
                        }
                    }
                }
                if !store.trendingSeries.isEmpty {
                    shelf("Trending Series", note: store.trendingFromTMDB ? "Trending on TMDB this week" : "Top rated") {
                        ForEach(store.trendingSeries) { s in
                            NavigationLink(value: IPTVRoute.series(s)) {
                                IPTVPoster(url: s.poster, title: s.name, subtitle: s.year.map(String.init), favorite: store.isFavorite(s.id), width: 220.s)
                            }
                            .buttonStyle(LiftButtonStyle())
                        }
                    }
                }
                if resume.isEmpty && recent.isEmpty && store.trendingMovies.isEmpty && store.trendingSeries.isEmpty {
                    Text(store.loading.isEmpty ? "Start watching and your channels, movies and series show up here." : "Loading your playlists…")
                        .foregroundStyle(.secondary).padding(60.s)
                }
            }
            .padding(.vertical, 30.s)
        }
        .scrollClipDisabled()
        .task(id: "\(store.movies.count)|\(store.series.count)") { await store.loadTrending(force: true) }
    }

    private func shelf<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8.s) {
            HStack(alignment: .lastTextBaseline, spacing: 16.s) {
                Text(title).font(.title3.bold())
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 60.s)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40.s) { content() }
                    .padding(.horizontal, 60.s).padding(.vertical, 24.s)
            }
            .scrollClipDisabled()
        }
        .tvFocusSection()
    }

    private func resumeCard(_ r: IPTVResume) -> some View {
        Button {
            if let id = r.movieID, let m = store.movie(id) { presenter.movie(m) }
            else if let sid = r.seriesID, let s = store.seriesItem(sid), let e = r.episode {
                Task {
                    let all = (try? await store.details(series: s).episodes) ?? [e]
                    // A finished episode continues with the next one.
                    if store.position(e.id) == nil, let i = all.firstIndex(where: { $0.id == e.id }), let next = all[safe: i + 1] {
                        presenter.episode(s, next, all: all)
                    } else {
                        presenter.episode(s, e, all: all)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12.s).fill(.white.opacity(0.06))
                    RemoteImage(url: r.poster.flatMap { URL(string: $0) }, placeholder: .clear)
                }
                .frame(width: 420.s, height: 236.s)
                .overlay(alignment: .bottom) { ProgressLine(progress: store.progress(r.id)) }
                .clipShape(RoundedRectangle(cornerRadius: 12.s, style: .continuous))
                Text(r.title).font(.callout).lineLimit(1)
                if let s = r.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 420.s)
        }
        .buttonStyle(LiftButtonStyle())
        .contextMenu { Button("Remove from Continue Watching") { store.removeResume(r.id) } }
    }

    private func channelCard(_ ch: IPTVChannel, lineup: [IPTVChannel]) -> some View {
        Button { presenter.live(ch, lineup: lineup) } label: {
            VStack(alignment: .leading, spacing: 8.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12.s).fill(.white.opacity(0.08))
                    ChannelLogo(channel: ch, size: 110.s)
                }
                .frame(width: 300.s, height: 170.s)
                HStack(spacing: 6.s) {
                    Text(ch.name).font(.caption.bold()).lineLimit(1)
                    ForEach(store.tags(ch).filter(\.isVideo).sorted { $0.rawValue < $1.rawValue }) { QualityBadge(tag: $0) }
                }
                Text(store.nowNext(ch).0?.title ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 300.s)
        }
        .buttonStyle(LiftButtonStyle())
    }
}
