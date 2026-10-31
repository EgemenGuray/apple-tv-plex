#if KSPLAYER
import KSPlayer
#endif
import SwiftUI
#if os(iOS)
import AVKit
#endif

/// Full-screen player. Resolves shows/seasons to the episode to play, then hands over to PlayerContainer.
struct PlayerScreen: View {
    let request: PlayerPresenter.Request
    @State private var item: PlexItem?
    @State private var error: String?
    private func dismiss() { PlayerPresenter.shared.close() }

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
                Text(err).padding(30.s).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16.s))
            }

            input
            if c.overlayVisible || c.scrubTime != nil {
                PlayerOverlay(c: c).transition(.opacity).allowsHitTesting(false)
            }
            #if !os(tvOS)
            if c.overlayVisible && c.panel == nil {
                TouchControls(c: c).transition(.opacity)
            }
            #endif
            if let intro = c.introMarker, c.panel == nil {
                tappable({ c.skipIntro() }) { SkipButton(title: "Skip Intro", detail: "\(Int(intro.end - c.time)) s") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90.s).padding(.bottom, c.overlayVisible ? 260.s : 90.s)
            }
            if let next = c.upNext, c.panel == nil {
                tappable({ c.playUpNext() }) { UpNextCard(item: next, countdown: c.upNextCountdown) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90.s).padding(.bottom, c.overlayVisible ? 260.s : 90.s)
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
        .onPlayPause {
            if c.scrubTime != nil { c.commitScrub() } else { c.togglePlay() }
        }
        .onBack(perform: back)
        .onAppear {
            c.onClose = close
            c.start(at: request.startAt)
            rootFocused = true
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onChange(of: c.panel) { _, p in if p == nil { rootFocused = true } }
        .onDisappear {
            TitleMemory.shared.flush()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }

    /// Siri Remote: a full-screen invisible button holds focus whenever no panel is open, and takes clicks and swipes.
    /// Touch, mouse and keyboard: tapping shows or hides the controls; Space, the arrow keys and Escape work as on
    /// the remote.
    @ViewBuilder private var input: some View {
        #if os(tvOS)
        Button { select() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
            .buttonStyle(InvisibleButtonStyle())
            .focused($rootFocused)
            .disabled(c.panel != nil)
            .onMoveCommand(perform: move)
        #else
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($rootFocused)
            .onTapGesture(count: 2) { c.togglePlay() }
            .onTapGesture {
                if c.panel != nil { c.panel = nil; c.hideOverlaySoon(); return }
                if c.overlayVisible && c.isPlaying { withAnimation { c.overlayVisible = false } }
                else { c.showOverlay(autoHide: c.isPlaying) }
            }
            .onContinuousHover { phase in
                if case .active = phase, !c.overlayVisible { c.showOverlay(autoHide: c.isPlaying) }
            }
            .onKeyPress(.space) {
                if c.scrubTime != nil { c.commitScrub() } else { c.togglePlay() }
                return .handled
            }
            .onKeyPress(.return) { select(); return .handled }
            .onKeyPress(.leftArrow) { move(.left); return .handled }
            .onKeyPress(.rightArrow) { move(.right); return .handled }
            .onKeyPress(.upArrow) { move(.up); return .handled }
            .onKeyPress(.downArrow) { move(.down); return .handled }
            .onKeyPress(.escape) { back(); return .handled }
        #endif
    }

    /// The Skip Intro and Up Next cards: the remote's click handles them on the TV; elsewhere they are buttons.
    @ViewBuilder private func tappable<L: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        if Platform.isTV {
            label()
        } else {
            Button(action: action, label: label).buttonStyle(.plain)
        }
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

/// Hosts the player's view (video plus its subtitle renderer).
#if os(macOS)
struct PlayerLayerView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    func makeNSView(context: Context) -> NSView {
        controller.layer?.makeUIView() ?? NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {
        controller.layer?.updateUIView(view)
    }
}
#else
struct PlayerLayerView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    func makeUIView(context: Context) -> UIView {
        controller.layer?.makeUIView() ?? UIView()
    }
    func updateUIView(_ view: UIView, context: Context) {
        controller.layer?.updateUIView(view)
    }
}
#endif

#if !os(tvOS)
/// On-screen controls for touch and mouse: close, panels and AirPlay at the top, transport in the middle, and a
/// draggable timeline (the overlay draws it; this layer takes the drag).
struct TouchControls: View {
    @ObservedObject var c: PlayerController
    @GestureState private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                control("xmark") { c.close() }
                Spacer()
                control("info.circle") { open(.info) }
                control("list.bullet") { open(.chapters) }
                control("speaker.wave.2") { open(.audio) }
                control("captions.bubble") { open(.subtitles) }
                control("aspectratio") { open(.picture) }
                #if os(iOS)
                RoutePicker().frame(width: 44, height: 44)
                #endif
            }
            .padding(.top, 70.s)
            Spacer()
            HStack(spacing: 70.s + 20) {
                control("gobackward.\(AppSettings.shared.skipBack)", big: false) { c.skip(-Double(AppSettings.shared.skipBack)) }
                control(c.isPlaying ? "pause.fill" : "play.fill", big: true) { c.togglePlay() }
                control("goforward.\(AppSettings.shared.skipForward)", big: false) { c.skip(Double(AppSettings.shared.skipForward)) }
            }
            Spacer()
            GeometryReader { g in
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { v in c.scrub(to: c.duration * Double(max(0, min(1, v.location.x / max(1, g.size.width))))) }
                            .onEnded { _ in c.commitScrub() }
                    )
            }
            .frame(height: 140.s + 24)
        }
        .padding(.horizontal, 90.s)
        .padding(.bottom, 20.s)
        .foregroundStyle(.white)
    }

    private func open(_ p: PlayerController.Panel) {
        c.panel = p
        c.showOverlay(autoHide: false)
    }

    private func control(_ symbol: String, big: Bool? = nil, action: @escaping () -> Void) -> some View {
        let size: CGFloat = big == true ? 72 : big == false ? 52 : 40
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .backgcontrol(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
#endif

#if os(iOS)
/// AirPlay and AirPods output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

struct SkipButton: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34).padding(.vertical, 18)
        .backgcontrol(.regularMaterial, in: Capsule())
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
        .backgcontrol(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
