import SwiftUI

/// Poster grid that loads more as you scroll, with sort, unwatched only, genre and collections.
struct LibraryView: View {
    let section: PlexSection
    @EnvironmentObject private var presenter: PlayerPresenter
    @State private var items: [PlexItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var sort = "titleSort"
    @State private var unwatched = false
    @State private var genre: PlexClient.Genre?
    @State private var genres: [PlexClient.Genre] = []
    @State private var showCollections = false
    @State private var collections: [PlexItem] = []
    @State private var error: String?

    private static let sorts: [(key: String, label: String)] = [
        ("titleSort", "Title"), ("addedAt:desc", "Date Added"), ("originallyAvailableAt:desc", "Release Date"),
        ("rating:desc", "Rating"), ("lastViewedAt:desc", "Recently Watched"),
    ]
    private let columns = posterColumns()

    init(section: PlexSection) {
        self.section = section
        // Films open newest release first; shows stay alphabetical.
        _sort = State(initialValue: section.type == "movie" ? "originallyAvailableAt:desc" : "titleSort")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30.s) {
                filterBar.scrollsHorizontallyOnSmallScreens().tvFocusSection()
                if let error { Text(error).foregroundStyle(.red) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 60.s) {
                    ForEach(showCollections ? collections : items) { item in
                        ItemLink(item: item) {
                            VStack(alignment: .leading, spacing: 8.s) {
                                PosterCard(item: item)
                                Text(item.title).font(.caption).lineLimit(1).frame(width: 260.s, alignment: .leading)
                            }
                        }
                        .onAppear { if !showCollections, item.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 80.s).padding(.vertical, 40.s)
        }
        .task(id: "\(sort)|\(unwatched)|\(genre?.key ?? "")") { await reload() }
        .task { genres = (try? await PlexClient.shared.genres(section.id)) ?? [] }
        .onChange(of: presenter.playbackEnded) { _, _ in Task { await reload() } }
        .environment(\.cardChanged, { item in Task { await refresh(item) } })
    }

    /// Reloads one card in place after its menu changed it, keeping the scroll position.
    private func refresh(_ item: PlexItem) async {
        guard let rk = item.ratingKey, let m = try? await PlexClient.shared.metadata(rk) else { return }
        if unwatched && m.isWatched { items.removeAll { $0.id == item.id }; total = max(0, total - 1); return }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = m }
    }

    private var filterBar: some View {
        HStack(spacing: 24.s) {
            Menu {
                ForEach(Self.sorts.indices, id: \.self) { i in
                    let s = Self.sorts[i]
                    Button { sort = s.key } label: { if sort == s.key { Label(s.label, systemImage: "checkmark") } else { Text(s.label) } }
                }
            } label: { Label(Self.sorts.first { $0.key == sort }?.label ?? "Sort", systemImage: "arrow.up.arrow.down") }
            Button { unwatched.toggle() } label: {
                Label("Unwatched", systemImage: unwatched ? "checkmark.circle.fill" : "circle")
            }
            Menu {
                Button("All Genres") { genre = nil }
                ForEach(genres) { g in Button(g.title) { genre = g } }
            } label: { Label(genre?.title ?? "Genre", systemImage: "line.3.horizontal.decrease.circle") }
            Button {
                showCollections.toggle()
                if showCollections && collections.isEmpty { Task { collections = (try? await PlexClient.shared.collections(section.id)) ?? [] } }
            } label: { Label("Collections", systemImage: showCollections ? "square.stack.3d.up.fill" : "square.stack.3d.up") }
            Spacer()
            Text(showCollections ? "\(collections.count) collections" : "\(total) titles").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func query(start: Int) -> PlexClient.ItemQuery {
        var q = PlexClient.ItemQuery()
        q.sort = sort; q.unwatched = unwatched; q.genre = genre?.key; q.start = start; q.size = 120
        return q
    }

    private func reload() async {
        items = []; total = 0; error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, items.isEmpty || items.count < total else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await PlexClient.shared.sectionItems(section.id, query(start: items.count))
            items += r.items; total = r.total
        } catch { self.error = error.localizedDescription }
    }
}

struct CollectionView: View {
    let collection: PlexItem
    @State private var items: [PlexItem] = []
    private let columns = posterColumns()

    var body: some View {
        ZStack {
            Backdrop(item: collection)
            ScrollView {
                VStack(alignment: .leading, spacing: 30.s) {
                    Text(collection.title).font(.largeTitle.bold())
                    if let s = collection.summary { Text(s).font(.callout).lineLimit(3).frame(maxWidth: 1200.s, alignment: .leading) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 60.s) {
                        ForEach(items) { item in ItemLink(item: item) { PosterCard(item: item) } }
                    }
                }
                .padding(80.s)
            }
        }
        .task { if let rk = collection.ratingKey { items = (try? await PlexClient.shared.collectionItems(rk)) ?? [] } }
    }
}

struct PersonView: View {
    let person: PlexPerson
    @State private var items: [PlexItem]?
    private let columns = posterColumns()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40.s) {
                HStack(spacing: 40.s) {
                    RemoteImage(url: PlexClient.shared.imageURL(person.thumb, width: 300, height: 300))
                        .frame(width: 200.s, height: 200.s).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 10.s) {
                        Text(person.name).font(.largeTitle.bold())
                        Text("In your libraries").foregroundStyle(.secondary)
                    }
                }
                if let items {
                    if items.isEmpty { Text("Nothing else in your libraries.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 60.s) {
                        ForEach(items) { item in
                            ItemLink(item: item) {
                                VStack(alignment: .leading, spacing: 6.s) {
                                    PosterCard(item: item)
                                    Text(item.title).font(.caption).lineLimit(1)
                                    Text(item.year.map(String.init) ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(width: 260.s, alignment: .leading)
                            }
                        }
                    }
                } else { ProgressView() }
            }
            .padding(80.s)
        }
        .task { await load() }
    }

    /// Everything they acted in, directed, wrote or produced, movies and shows together, newest first.
    private func load() async {
        var all: [PlexItem] = []
        var seen = Set<String>()
        for kind in [PlexPerson.Kind.actor, .director, .writer, .producer] {
            let p = PlexPerson(raw: person.raw, kind: kind)
            for it in await PlexClient.shared.personItems(p) where seen.insert(it.id).inserted { all.append(it) }
        }
        items = all.sorted { ($0.originallyAvailableAt ?? "") > ($1.originallyAvailableAt ?? "") }
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var results: [PlexItem] = []
    /// The last 10 searches, newest first, one per line.
    @AppStorage("plex.recentSearches") private var recentRaw = ""
    private let columns = posterColumns()

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty && !recent.isEmpty {
                recentList
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 60.s) {
                ForEach(results) { item in
                    ItemLink(item: item) {
                        VStack(alignment: .leading, spacing: 6.s) {
                            PosterCard(item: item)
                            Text(item.type == "episode" ? "\(item.grandparentTitle ?? "") · \(item.title)" : item.title).font(.caption).lineLimit(1)
                        }
                        .frame(width: 260.s, alignment: .leading)
                    }
                }
            }
            .padding(80.s)
        }
        .searchable(text: $query, prompt: "Movies, shows, episodes")
        .onSubmit(of: .search) { remember(query, submitted: true) }
        .environment(\.cardChanged, { item in Task { await refresh(item) } })
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            results = (try? await PlexClient.shared.search(q)) ?? []
            // A search that found something is remembered once typing has paused.
            guard !results.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { remember(q) }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 20.s) {
            HStack {
                Text("Recent Searches").font(.title3.bold())
                Spacer()
                Button("Clear") { recentRaw = "" }
            }
            .tvFocusSection()
            VStack(alignment: .leading, spacing: 8.s) {
                ForEach(recent, id: \.self) { q in
                    Button { query = q } label: {
                        Label(q, systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.plain)
                    .padding(.vertical, 6.s)
                    #endif
                }
            }
            .tvFocusSection()
        }
        .frame(maxWidth: 1200.s, alignment: .leading)
        .padding(.horizontal, 80.s).padding(.top, 40.s)
    }

    /// Adds a search to the top of the list. Typing "bre", "brea", "break" keeps only "break"; deleting letters
    /// back to "bre" doesn't add it again unless it is submitted.
    private func remember(_ raw: String, submitted: Bool = false) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        let lq = q.lowercased()
        if !submitted && recent.contains(where: { $0.lowercased() != lq && $0.lowercased().hasPrefix(lq) }) { return }
        var list = recent.filter { !lq.hasPrefix($0.lowercased()) }
        list.insert(q, at: 0)
        recentRaw = list.prefix(10).joined(separator: "\n")
    }

    private func refresh(_ item: PlexItem) async {
        guard let rk = item.ratingKey, let m = try? await PlexClient.shared.metadata(rk),
              let i = results.firstIndex(where: { $0.id == item.id }) else { return }
        results[i] = m
    }
}
