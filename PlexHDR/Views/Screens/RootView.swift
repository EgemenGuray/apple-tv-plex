import CoreImage.CIFilterBuiltins
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
        .playerPresentation(presenter)
    }
}

extension View {
    /// The player covers the whole screen: a full-screen cover on Apple TV, iPhone and iPad, an overlay in the Mac
    /// window (macOS has no full-screen cover).
    @ViewBuilder func playerPresentation(_ presenter: PlayerPresenter) -> some View {
        #if os(macOS)
        ZStack {
            self
            if let req = presenter.request {
                PlayerScreen(request: req).id(req.id).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: presenter.request?.id)
        #else
        fullScreenCover(item: Binding(get: { presenter.request }, set: { presenter.request = $0 }),
                        onDismiss: { presenter.playbackEnded += 1 }) { req in
            PlayerScreen(request: req)
        }
        #endif
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
    @State private var qrPin: PlexClient.Pin?
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 50.s) {
            Text("Sign in to Plex").font(.largeTitle.bold())
            if let pin {
                if !Platform.isTV, let qrPin {
                    // On a phone, tablet or Mac the browser is right here.
                    Button { openURL(plex.authURL(code: qrPin.code)) } label: {
                        Label("Sign in with Plex in the browser", systemImage: "safari").padding(.horizontal, 20.s).padding(.vertical, 8.s)
                    }
                    .buttonStyle(.borderedProminent)
                }
                ViewThatFits {
                    HStack(alignment: .center, spacing: 120.s) { signInMethods(pin) }
                    VStack(spacing: 50.s) { signInMethods(pin) }
                }
                ProgressView()
            } else if let error {
                ErrorView(message: error) { Task { await start() } }
            } else {
                ProgressView()
            }
        }
        .padding()
        .task { await start() }
    }

    @ViewBuilder private func signInMethods(_ pin: PlexClient.Pin) -> some View {
        if !Platform.isPhone {
            VStack(spacing: 24.s) {
                if let qrPin, let qr = QRCode.image(for: plex.authURL(code: qrPin.code)) {
                    Image(uiImage: qr).interpolation(.none).resizable()
                        .frame(width: 420.s, height: 420.s)
                        .padding(24.s).background(.white, in: RoundedRectangle(cornerRadius: 24.s))
                }
                Text("Scan with your phone").foregroundStyle(.secondary)
            }
        }
        VStack(spacing: 30.s) {
            Text(Platform.isTV ? "Or go to" : "Or on any device go to").foregroundStyle(.secondary)
            Text("plex.tv/link").font(.system(size: 64.s, weight: .bold))
            Text("and enter").foregroundStyle(.secondary)
            Text(pin.code).font(.system(size: 110.s, weight: .heavy, design: .monospaced)).kerning(20.s)
        }
    }

    private func start() async {
        error = nil
        do {
            let p = try await plex.createPin()
            let q = try? await plex.createPin(strong: true)
            pin = p
            qrPin = q
            // The codes are valid for 15 minutes; poll both every 2 s.
            for _ in 0..<450 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if try await plex.checkPin(p) { return }
                if let q, (try? await plex.checkPin(q)) == true { return }
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
        VStack(spacing: 40.s) {
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
                    .frame(maxWidth: 900.s)
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


enum QRCode {
    static func image(for url: URL) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
