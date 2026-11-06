#if KSPLAYER
import KSPlayer
#endif
import SwiftUI

/// The IPTV sections. In Live TV mode each one is its own tab. Downloads are shown inside Recordings; the case
/// stays for its own search text.
enum IPTVSection: String, CaseIterable, Identifiable {
    case home, live, guide, movies, series, favorites, search, recordings, playlists, settings, downloads
    var id: String { rawValue }
    /// The tabs, in order.
    static let tabs: [IPTVSection] = [.home, .live, .guide, .movies, .series, .favorites, .search, .recordings, .playlists, .settings]
    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .guide: return "Guide"
        case .movies: return "Movies"
        case .series: return "Series"
        case .favorites: return "Favorites"
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .recordings: return "Recordings"
        case .playlists: return "Sources"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .live: return "tv"
        case .guide: return "calendar"
        case .movies: return "film"
        case .series: return "play.rectangle.on.rectangle"
        case .favorites: return "star"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .recordings: return "record.circle"
        case .playlists: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
    /// Works without any source added.
    var needsNoSource: Bool { [.playlists, .downloads, .recordings, .settings].contains(self) }
}

enum IPTVRoute: Hashable {
    case movie(IPTVMovie)
    case series(IPTVSeries)
}

extension View {
    func iptvRoutes() -> some View {
        navigationDestination(for: IPTVRoute.self) { r in
            switch r {
            case let .movie(m): IPTVMovieDetail(movie: m)
            case let .series(s): IPTVSeriesDetail(series: s)
            }
        }
    }
}

/// One section, or the first-run screen when no playlist has been added.
struct IPTVSectionView: View {
    let section: IPTVSection
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        Group {
            if !store.hasSources && !section.needsNoSource {
                IPTVWelcome()
            } else {
                switch section {
                case .home: IPTVHomeFeed()
                case .live: LiveTVView()
                case .guide: GuideView()
                case .movies: MoviesView()
                case .series: SeriesView()
                case .favorites: IPTVFavoritesView()
                case .search: IPTVSearchView()
                case .downloads: JobsView(kind: .download)
                case .recordings: RecordingsView()
                case .playlists: PlaylistsView(part: .sources)
                case .settings: PlaylistsView(part: .settings)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct IPTVWelcome: View {
    @State private var adding = false
    var body: some View {
        VStack(spacing: 36.s) {
            Image(systemName: "tv.and.mediabox").font(.system(size: 120.s))
            Text("Watch live TV in Lumen").font(.title.bold())
            Text("Add an M3U playlist or an Xtream Codes login from your TV provider. Lumen reads its channels, TV guide, catch-up, movies and series.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 1100.s)
            Button { adding = true } label: { Label("Add Playlist", systemImage: "plus").padding(.horizontal, 30.s).padding(.vertical, 10.s) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .sheet(isPresented: $adding) { PlaylistEditor(playlist: nil) }
    }
}

// MARK: - Shared pieces

struct PillStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, selected: selected) }
    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? .black : .white)
                .background(Capsule().fill(focused ? .white : selected ? .white.opacity(0.25) : .white.opacity(0.06)))
                .scaleEffect(focused ? 1.06 : configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
                .contentShape(Capsule())
        }
    }
}

struct QualityBadge: View {
    let tag: IPTVTag
    var body: some View {
        Text(tag.rawValue).font(.system(size: 18.s, weight: .bold))
            .padding(.horizontal, 7.s).padding(.vertical, 2.s)
            .foregroundStyle(tag == .uhd || tag == .hdr ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 4.s).fill(color))
    }
    private var color: Color {
        switch tag {
        case .uhd: return .yellow
        case .hdr: return .orange
        case .fhd: return .blue
        case .hd: return .teal
        case .surround: return .purple
        default: return .gray.opacity(0.6)
        }
    }
}

struct SourceDot: View {
    let playlistID: UUID
    var body: some View {
        Circle().fill(IPTVStore.shared.playlist(playlistID)?.color ?? .gray).frame(width: 12.s, height: 12.s)
    }
}

/// PIN entry for locked groups.
struct PINPrompt: ViewModifier {
    @Binding var isPresented: Bool
    var onUnlock: () -> Void = {}
    @State private var pin = ""
    @State private var wrong = false
    func body(content: Content) -> some View {
        content.alert(wrong ? "Wrong PIN" : "Enter PIN", isPresented: $isPresented) {
            SecureField("PIN", text: $pin)
            Button("Unlock") {
                if IPTVStore.shared.unlock(pin) { wrong = false; onUnlock() } else { wrong = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isPresented = true } }
                pin = ""
            }
            Button("Cancel", role: .cancel) { pin = ""; wrong = false }
        } message: { Text("This group is locked.") }
    }
}

extension View {
    func pinPrompt(_ shown: Binding<Bool>, onUnlock: @escaping () -> Void = {}) -> some View { modifier(PINPrompt(isPresented: shown, onUnlock: onUnlock)) }
}

// MARK: - Preview

/// A small muted player for the focused channel.
@MainActor
final class PreviewPlayer: ObservableObject, KSPlayerLayerDelegate {
    @Published private(set) var layer: KSPlayerLayer?
    @Published private(set) var channelID: String?
    @Published private(set) var ready = false

    func load(_ ch: IPTVChannel) {
        guard channelID != ch.id, let url = URL(string: ch.url) else { return }
        stop()
        channelID = ch.id
        let o = KSOptions()
        o.isLive = true
        o.registerRemoteControll = false
        o.autoSelectEmbedSubtitle = false
        if let ua = ch.userAgent, !ua.isEmpty { o.userAgent = ua }
        o.playerTypes = [KSMEPlayer.self, KSAVPlayer.self]
        let l = KSPlayerLayer(url: url, options: o, delegate: nil)
        l.delegate = self
        l.player.isMuted = true
        layer = l
    }

    func stop() {
        layer?.delegate = nil
        layer?.stop()
        layer = nil
        channelID = nil
        ready = false
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        layer.player.isMuted = true
        if state == .readyToPlay || state == .bufferFinished { ready = true }
    }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {}
    func player(layer: KSPlayerLayer, finish error: Error?) { ready = false }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

#if os(macOS)
struct PreviewLayerView: NSViewRepresentable {
    let layer: KSPlayerLayer
    func makeNSView(context: Context) -> NSView { layer.makeUIView() }
    func updateNSView(_ view: NSView, context: Context) { layer.updateUIView(view) }
}
#else
struct PreviewLayerView: UIViewRepresentable {
    let layer: KSPlayerLayer
    func makeUIView(context: Context) -> UIView { layer.makeUIView() }
    func updateUIView(_ view: UIView, context: Context) { layer.updateUIView(view) }
}
#endif
