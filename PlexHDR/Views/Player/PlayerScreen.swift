import KSPlayer
import SwiftUI

/// Full-screen player. Resolves shows/seasons to the episode to play, then hands over to PlayerContainer.
struct PlayerScreen: View {
    let request: PlayerPresenter.Request
    @State private var item: PlexItem?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                PlayerContainer(item: item, request: request) { dismiss() }
            } else if let error {
                ErrorView(message: error) { dismiss() }
            } else {
                ProgressView()
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        let pc = PlexClient.shared
        var it = request.item
        do {
            if it.type == "show" || it.type == "season", let rk = it.ratingKey {
                var show: PlexItem?
                if it.type == "show" { show = try await pc.metadata(rk) }
                if let deck = show?.onDeck { it = deck } else {
                    var seasons = [it]
                    if it.type == "show" { seasons = try await pc.children(rk).filter { ($0.index ?? 0) > 0 } }
                    var pick: PlexItem?
                    for s in seasons {
                        guard let sk = s.ratingKey else { continue }
                        let eps = try await pc.children(sk)
                        if let e = eps.first(where: { !$0.isWatched }) { pick = e; break }
                        if pick == nil { pick = eps.first }
                    }
                    guard let pick else { throw PlexError.message("No episodes to play.") }
                    it = pick
                }
            }
            // Full metadata: markers, chapters and every stream.
            if let rk = it.ratingKey, let full = try await pc.metadata(rk) { it = full }
            guard it.media.first?.part != nil else { throw PlexError.message("This item has no playable file.") }
            item = it
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlayerContainer: View {
    @StateObject private var c: PlayerController
    let request: PlayerPresenter.Request
    let close: () -> Void
    @FocusState private var rootFocused: Bool

    init(item: PlexItem, request: PlayerPresenter.Request, close: @escaping () -> Void) {
        _c = StateObject(wrappedValue: PlayerController(item: item, mediaIndex: request.mediaIndex, audioId: request.audioId, subtitleId: request.subtitleId))
        self.request = request
        self.close = close
    }

    var body: some View {
        ZStack {
            Color.black
            if c.layer != nil {
                PlayerLayerView(controller: c).ignoresSafeArea()
            }
            if c.state == .preparing || c.state == .buffering {
                ProgressView().scaleEffect(1.5)
            }
            if let err = c.error {
                Text(err).padding(30).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }

            // Remote input: a full-screen invisible button holds focus whenever no panel is open.
            Button { select() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(InvisibleButtonStyle())
                .focused($rootFocused)
                .disabled(c.panel != nil)
                .onMoveCommand(perform: move)

            if c.overlayVisible || c.scrubTime != nil {
                PlayerOverlay(c: c).transition(.opacity).allowsHitTesting(false)
            }
            if let intro = c.introMarker, c.panel == nil {
                SkipButton(title: "Skip Intro", detail: "\(Int(intro.end - c.time)) s")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90).padding(.bottom, c.overlayVisible ? 260 : 90)
            }
            if let next = c.upNext, c.panel == nil {
                UpNextCard(item: next, countdown: c.upNextCountdown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90).padding(.bottom, c.overlayVisible ? 260 : 90)
            }
            if c.panel != nil {
                PlayerPanel(c: c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: c.panel)
        .animation(.easeInOut(duration: 0.3), value: c.overlayVisible)
        .onPlayPauseCommand {
            if c.scrubTime != nil { c.commitScrub() } else { c.togglePlay() }
        }
        .onExitCommand(perform: back)
        .onAppear {
            c.onClose = close
            c.start(at: request.startAt)
            rootFocused = true
        }
        .onChange(of: c.panel) { _, p in if p == nil { rootFocused = true } }
        .onDisappear { TitleMemory.shared.flush() }
    }

    private func select() {
        if c.scrubTime != nil { c.commitScrub(); return }
        if c.upNext != nil { c.playUpNext(); return }
        if c.introMarker != nil { c.skipIntro(); return }
        c.togglePlay()
    }

    private func move(_ d: MoveCommandDirection) {
        switch d {
        case .left, .right:
            let dir = d == .left ? -1 : 1
            if c.upNext != nil, d == .left { c.dismissUpNext(); return }
            if !c.isPlaying || c.scrubTime != nil { c.scrub(dir) }
            else { c.skip(Double(dir > 0 ? AppSettings.shared.skipForward : -AppSettings.shared.skipBack)) }
        case .up:
            c.showOverlay(autoHide: c.isPlaying)
        case .down:
            c.panel = .info
            c.showOverlay(autoHide: false)
        @unknown default: break
        }
    }

    private func back() {
        if c.panel != nil { c.panel = nil; c.hideOverlaySoon(); return }
        if c.scrubTime != nil { c.cancelScrub(); return }
        if c.upNext != nil { c.dismissUpNext(); return }
        if c.overlayVisible && c.isPlaying { withAnimation { c.overlayVisible = false }; return }
        c.close()
    }
}

struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.contentShape(Rectangle()) }
}

/// Hosts KSPlayer's view (video plus its subtitle renderer).
struct PlayerLayerView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    func makeUIView(context: Context) -> UIView {
        controller.layer?.makeUIView() ?? UIView()
    }
    func updateUIView(_ view: UIView, context: Context) {
        controller.layer?.updateUIView(view)
    }
}

struct SkipButton: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34).padding(.vertical, 18)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 2))
    }
}

struct UpNextCard: View {
    let item: PlexItem
    let countdown: Int
    var body: some View {
        HStack(spacing: 24) {
            RemoteImage(url: PlexClient.shared.imageURL(item.thumb, width: 480, height: 270))
                .frame(width: 320, height: 180).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next in \(countdown)").font(.caption).foregroundStyle(.secondary)
                Text(item.episodeLabel ?? "").font(.caption.bold())
                Text(item.title).font(.headline).lineLimit(2)
                Text("Click to play now · ◀ to keep watching").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 380, alignment: .leading)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
