import SwiftUI

struct RootView: View {
    @EnvironmentObject private var plex: PlexClient
    @EnvironmentObject private var presenter: PlayerPresenter

    var body: some View {
        Group {
            if plex.token == nil {
                SignInView()
            } else if plex.server == nil {
                ServerPickerView()
            } else {
                MainTabs()
            }
        }
        .fullScreenCover(item: $presenter.request, onDismiss: { presenter.playbackEnded += 1 }) { req in
            PlayerScreen(request: req)
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var plex: PlexClient
    @State private var sections: [PlexSection] = []
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView().withRoutes() }
                .tabItem { Text("Home") }.tag("home")
            ForEach(sections.filter(\.isVideo)) { s in
                NavigationStack { LibraryView(section: s).withRoutes() }
                    .tabItem { Text(s.title) }.tag("lib-\(s.id)")
            }
            NavigationStack { SearchView().withRoutes() }
                .tabItem { Image(systemName: "magnifyingglass") }.tag("search")
            NavigationStack { SettingsView() }
                .tabItem { Image(systemName: "gearshape") }.tag("settings")
        }
        .task(id: plex.server?.machineId) {
            sections = (try? await plex.sections()) ?? []
        }
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .item(item):
                if item.type == "show" || item.type == "season" { ShowView(item: item) }
                else if item.type == "collection" { CollectionView(collection: item) }
                else { DetailView(item: item) }
            case let .person(p): PersonView(person: p)
            case let .collection(c): CollectionView(collection: c)
            }
        }
    }
}

// MARK: - Sign-in

struct SignInView: View {
    @EnvironmentObject private var plex: PlexClient
    @State private var pin: PlexClient.Pin?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 50) {
            Text("Sign in to Plex").font(.largeTitle.bold())
            if let pin {
                Text("On your phone or computer, go to").foregroundStyle(.secondary)
                Text("plex.tv/link").font(.system(size: 64, weight: .bold))
                Text(pin.code).font(.system(size: 120, weight: .heavy, design: .monospaced)).kerning(24)
                ProgressView()
            } else if let error {
                ErrorView(message: error) { Task { await start() } }
            } else {
                ProgressView()
            }
        }
        .task { await start() }
    }

    private func start() async {
        error = nil
        do {
            let p = try await plex.createPin()
            pin = p
            // The code is valid for 15 minutes; poll every 2 s.
            for _ in 0..<450 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if try await plex.checkPin(p) { return }
            }
            pin = nil
            error = "The code expired."
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ServerPickerView: View {
    @EnvironmentObject private var plex: PlexClient
    @State private var servers: [JSON] = []
    @State private var loading = true
    @State private var error: String?
    @State private var connecting: String?

    var body: some View {
        VStack(spacing: 40) {
            Text("Choose a server").font(.largeTitle.bold())
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(servers.indices, id: \.self) { i in
                let s = servers[i]
                Button {
                    Task { await connect(s) }
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading) {
                            Text(s["name"] as? String ?? "Plex")
                            Text((s["owned"] as? Bool) == true ? "Owned" : "Shared").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connecting == s["clientIdentifier"] as? String { ProgressView() }
                    }
                    .frame(width: 900)
                }
            }
            Button("Sign Out", role: .destructive) { plex.signOut() }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            servers = try await plex.listServers()
            if servers.count == 1 { await connect(servers[0]) }
        } catch { self.error = error.localizedDescription }
    }

    private func connect(_ s: JSON) async {
        connecting = s["clientIdentifier"] as? String
        defer { connecting = nil }
        do { try await plex.connect(s) } catch { self.error = error.localizedDescription }
    }
}
