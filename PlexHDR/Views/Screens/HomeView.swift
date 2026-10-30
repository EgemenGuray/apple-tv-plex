import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var plex: PlexClient
    @EnvironmentObject private var presenter: PlayerPresenter
    @State private var shelf: [PlexItem] = []
    @State private var continueWatching: [PlexItem] = []
    @State private var recent: [SectionRow] = []
    struct SectionRow: Identifiable { let section: PlexSection; let items: [PlexItem]; var id: String { section.id } }
    @State private var heroIndex = 0
    @State private var focusedItem: PlexItem?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ZStack {
            Backdrop(item: focusedItem ?? shelf[safe: heroIndex])
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 30) {
                    if !shelf.isEmpty {
                        TopShelf(items: shelf, index: $heroIndex)
                            .frame(height: 840)
                            .onChange(of: heroIndex) { _, _ in focusedItem = nil }
                    }
                    if !continueWatching.isEmpty {
                        ItemRow(title: "Continue Watching", items: continueWatching, wide: true) { focusedItem = $0 }
                    }
                    ForEach(recent) { row in
                        ItemRow(title: "Recently Added in \(row.section.title)", items: row.items) { focusedItem = $0 }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            if let error, !loaded { ErrorView(message: error) { Task { await load() } } }
            else if !loaded { LoadingView() }
        }
        .ignoresSafeArea(edges: .top)
        .task { if !loaded { await load() } }
        .onChange(of: presenter.playbackEnded) { _, _ in Task { await load() } }
    }

    private func load() async {
        error = nil
        do {
            async let deck = plex.onDeck()
            let sections = try await plex.sections().filter(\.isVideo)
            var rows: [SectionRow] = []
            for s in sections {
                if let items = try? await plex.recentlyAdded(s.id), !items.isEmpty { rows.append(SectionRow(section: s, items: items)) }
            }
            continueWatching = (try? await deck) ?? []
            recent = rows
            // Top shelf: what you're watching first, then the newest films and shows, de-duplicated by show.
            var seen = Set<String>()
            var picks: [PlexItem] = []
            for it in continueWatching.prefix(4) + rows.flatMap({ $0.items.prefix(4) }) {
                let k = it.grandparentRatingKey ?? it.ratingKey ?? it.id
                if seen.insert(k).inserted { picks.append(it) }
            }
            shelf = Array(picks.prefix(10))
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Full-screen top shelf: artwork, logo, metadata, summary and Play / More Info. Moves to the next title every 9 s
/// while you rest on it; ◀ ▶ past the buttons flips between titles.
struct TopShelf: View {
    let items: [PlexItem]
    @Binding var index: Int
    @EnvironmentObject private var presenter: PlayerPresenter
    @State private var details: [String: PlexItem] = [:]
    @State private var ratings: Online.Ratings?
    @FocusState private var focus: Field?
    enum Field { case play, info }

    private var item: PlexItem { items[min(index, items.count - 1)] }
    /// Episodes on the shelf show their series' artwork and logo.
    private var full: PlexItem { details[item.id] ?? item }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            TitleLogo(item: full)
            HStack(spacing: 16) {
                if let ep = item.episodeLabel { Text("\(ep) · \(item.title)") }
                if let y = full.year { Text(String(y)) }
                if let r = full.contentRating { Badge(text: r) }
                if let d = formatDuration(full.durationMs) { Text(d) }
                if !full.genres.isEmpty { Text(full.genres.prefix(3).joined(separator: ", ")) }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let ratings, !ratings.isEmpty, AppSettings.shared.showRatings { RatingsRow(ratings: ratings) }
            Text(full.summary ?? "").font(.callout).lineLimit(3).frame(maxWidth: 1000, alignment: .leading).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 30) {
                Button {
                    presenter.play(full)
                } label: {
                    Label(item.viewOffsetMs > 0 ? "Resume" : "Play", systemImage: "play.fill").frame(minWidth: 220)
                }
                .focused($focus, equals: .play)
                NavigationLink(value: Route.item(item.type == "episode" ? item : full)) {
                    Label("More Info", systemImage: "info.circle").frame(minWidth: 220)
                }
                .focused($focus, equals: .info)
                Spacer()
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { i in
                        Circle().fill(i == index ? .white : .white.opacity(0.35)).frame(width: 12, height: 12)
                    }
                }
            }
            .onMoveCommand { dir in
                if dir == .left && focus == .play { flip(-1) }
                if dir == .right && focus == .info { flip(1) }
            }
        }
        .padding(.horizontal, 80).padding(.bottom, 40)
        .focusSection()
        .task(id: item.id) {
            if details[item.id] == nil, let rk = item.ratingKey, let m = try? await PlexClient.shared.metadata(rk) { details[item.id] = m }
            ratings = nil
            ratings = await Online.shared.ratings(details[item.id] ?? item)
        }
        .task(id: "\(index)-\(focus != nil)") {
            // Auto-advance only while the shelf has focus, like the Apple TV app.
            guard focus != nil, items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !Task.isCancelled { flip(1) }
        }
    }

    private func flip(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.4)) { index = (index + d + items.count) % items.count }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
