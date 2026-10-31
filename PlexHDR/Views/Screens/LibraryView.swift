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
    private let columns = posterColumns()

    var body: some View {
        ScrollView {
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
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            results = (try? await PlexClient.shared.search(q)) ?? []
        }
    }
}
