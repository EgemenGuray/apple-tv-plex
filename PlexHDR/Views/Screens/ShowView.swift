import SwiftUI

/// Show page: backdrop, Play/Resume next episode, Mark watched, season pills, episodes with stills, cast & crew,
/// more like this.
struct ShowView: View {
    let item: PlexItem     // a show or a season
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var settings: AppSettings
    @State private var show: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var seasonKey: String?
    @State private var episodes: [PlexItem] = []
    @State private var similar: [PlexItem] = []
    @State private var ratings: Online.Ratings?

    private var s: PlexItem { show ?? item }
    /// The episode Play starts: Plex's On Deck for the show, else the first unwatched, else the first.
    private var nextUp: PlexItem? { s.onDeck ?? episodes.first { !$0.isWatched } ?? episodes.first }

    var body: some View {
        ZStack {
            Backdrop(item: s)
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    header.frame(minHeight: 780, alignment: .bottomLeading)
                    seasonPills
                    if !episodes.isEmpty { episodeRow }
                    CastRow(item: s)
                    if !similar.isEmpty { ItemRow(title: "More Like This", items: similar) }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea(edges: .top)
        .task { await load() }
        .task(id: seasonKey) {
            guard let seasonKey else { return }
            episodes = (try? await PlexClient.shared.children(seasonKey)) ?? []
        }
        .onChange(of: presenter.playbackEnded) { _, _ in Task { await load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 200)
            TitleLogo(item: s)
            HStack(spacing: 16) {
                if let y = s.year { Text(String(y)) }
                if let r = s.contentRating { Badge(text: r) }
                if let n = s.childCount { Text("\(n) Season\(n == 1 ? "" : "s")") }
                if !s.genres.isEmpty { Text(s.genres.prefix(3).joined(separator: ", ")) }
                if let st = s.studio { Text(st) }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let ratings, !ratings.isEmpty, settings.showRatings { RatingsRow(ratings: ratings) }
            Text(s.summary ?? "").font(.callout).lineLimit(4).frame(maxWidth: 1200, alignment: .leading)
            HStack(spacing: 24) {
                if let ep = nextUp {
                    Button { presenter.play(ep) } label: {
                        Label(ep.viewOffsetMs > 0 ? "Resume \(ep.episodeLabel ?? "")" : "Play \(ep.episodeLabel ?? "")", systemImage: "play.fill")
                    }
                }
                Button {
                    Task { await PlexClient.shared.setWatched(s, !s.isWatched); await load() }
                } label: { Label(s.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: s.isWatched ? "checkmark.circle.fill" : "checkmark.circle") }
            }
            .focusSection()
        }
        .padding(.horizontal, 80)
    }

    private var seasonPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(seasons) { season in
                    SeasonPill(title: season.title, selected: season.ratingKey == seasonKey) {
                        // Moving onto a season loads it.
                        seasonKey = season.ratingKey
                    }
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 20)
        }
        .focusSection()
    }

    private var episodeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 40) {
                ForEach(episodes) { ep in
                    NavigationLink(value: Route.item(ep)) {
                        VStack(alignment: .leading, spacing: 8) {
                            RemoteImage(url: PlexClient.shared.imageURL(ep.thumb, width: 720, height: 405))
                                .frame(width: 480, height: 270)
                                .overlay(alignment: .bottom) { ProgressLine(progress: ep.progress) }
                                .overlay(alignment: .topTrailing) {
                                    if ep.isWatched { Image(systemName: "checkmark.circle.fill").padding(10) }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text("\(ep.index ?? 0). \(ep.title)").font(.callout).lineLimit(1)
                            Text(ep.summary ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            if let d = formatDuration(ep.durationMs) { Text(d).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 480, alignment: .leading)
                    }
                    .buttonStyle(LiftButtonStyle())
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func load() async {
        let pc = PlexClient.shared
        let showKey = item.type == "season" ? item.parentRatingKey : item.ratingKey
        guard let showKey else { return }
        if let m = try? await pc.metadata(showKey) { show = m }
        seasons = ((try? await pc.children(showKey)) ?? []).filter { $0.type == "season" }
        if seasonKey == nil {
            if item.type == "season" { seasonKey = item.ratingKey }
            else if let deck = show?.onDeck, let sk = deck.parentRatingKey { seasonKey = sk }
            else { seasonKey = (seasons.first { !$0.isWatched && ($0.index ?? 0) > 0 } ?? seasons.first)?.ratingKey }
        } else if let sk = seasonKey {
            episodes = (try? await pc.children(sk)) ?? []
        }
        similar = await pc.similar(showKey)
        ratings = await Online.shared.ratings(s)
    }
}

/// A season button that selects its season as soon as it gets focus.
struct SeasonPill: View {
    let title: String
    let selected: Bool
    let select: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: select) {
            Text(title).font(.callout.weight(.semibold))
        }
        .focused($focused)
        .tint(selected ? .white : nil)
        .onChange(of: focused) { _, f in if f { select() } }
    }
}
