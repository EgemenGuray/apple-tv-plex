import AVFoundation
#if KSPLAYER
import KSPlayer
#endif
import SwiftUI

/// "Play this" for IPTV: live channels (with zapping through the list they were picked from), catch-up programmes,
/// films and episodes.
@MainActor
final class IPTVPlayerPresenter: ObservableObject {
    static let shared = IPTVPlayerPresenter()
    enum Kind {
        case live(IPTVChannel)
        case catchup(IPTVChannel, IPTVProgramme)
        case movie(IPTVMovie)
        case episode(IPTVSeries, IPTVEpisode, [IPTVEpisode])
        case file(IPTVRecorder.Job)
    }
    struct Request: Identifiable {
        let id = UUID()
        var kind: Kind
        var lineup: [IPTVChannel] = []
    }
    @Published var request: Request?

    func live(_ ch: IPTVChannel, lineup: [IPTVChannel]) { request = Request(kind: .live(ch), lineup: lineup.isEmpty ? [ch] : lineup) }
    func catchup(_ ch: IPTVChannel, _ p: IPTVProgramme) { request = Request(kind: .catchup(ch, p)) }
    func movie(_ m: IPTVMovie) { request = Request(kind: .movie(m)) }
    func episode(_ s: IPTVSeries, _ e: IPTVEpisode, all: [IPTVEpisode]) { request = Request(kind: .episode(s, e, all)) }
    func file(_ j: IPTVRecorder.Job) { request = Request(kind: .file(j)) }
    func close() { request = nil }
}

@MainActor
final class IPTVPlayerController: ObservableObject {
    enum Panel { case channels, tracks }

    @Published private(set) var kind: IPTVPlayerPresenter.Kind
    @Published private(set) var state: KSPlayerState = .preparing
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var overlayVisible = true
    @Published var panel: Panel?
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var layerVersion = 0
    @Published var fit: PlayerController.Fit = .fit { didSet { layer?.player.contentMode = fit.mode } }
    @Published private(set) var audioTracks: [any MediaPlayerTrack] = []
    @Published private(set) var subtitles: [any SubtitleInfo] = []
    @Published private(set) var subtitleID: String?
    /// Digits typed on a keyboard to jump to a channel number.
    @Published private(set) var typedNumber = ""

    let lineup: [IPTVChannel]
    private(set) var layer: KSPlayerLayer?
    private var previousChannel: IPTVChannel?
    private var retries = 0
    private var hideTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var numberTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    var onClose: (() -> Void)?

    init(request: IPTVPlayerPresenter.Request) {
        kind = request.kind
        lineup = request.lineup
    }

    var store: IPTVStore { .shared }

    var isLive: Bool { if case .live = kind { return true }; return false }
    var channel: IPTVChannel? {
        switch kind {
        case let .live(c), let .catchup(c, _): return c
        default: return nil
        }
    }
    var isPlaying: Bool { state.isPlaying }

    /// Resume key for films and episodes.
    private var resumeID: String? {
        switch kind {
        case let .movie(m): return m.id
        case let .episode(_, e, _): return e.id
        case let .file(j): return "file|\(j.id.uuidString)"
        default: return nil
        }
    }

    var title: String {
        switch kind {
        case let .live(c): return c.name
        case let .catchup(_, p): return p.title
        case let .movie(m): return m.name
        case let .episode(s, e, _): return "\(s.name) · \(e.label)"
        case let .file(j): return j.title
        }
    }

    // MARK: - Opening

    func start() {
        noteWatching()
        var at: TimeInterval = 0
        if let id = resumeID { at = store.position(id) ?? 0 }
        open(at: at)
        hideSoon()
    }

    private func noteWatching() {
        switch kind {
        case let .movie(m): store.noteWatching(movie: m)
        case let .episode(s, e, _): store.noteWatching(series: s, episode: e)
        default: break
        }
    }

    private func streamURL() -> (String?, String?) {
        switch kind {
        case let .live(c):
            store.played(c)
            return (c.url, c.userAgent)
        case let .catchup(c, p): return (store.catchupURL(c, p), c.userAgent)
        case let .movie(m): return (m.url, store.playlist(m.playlistID)?.userAgent)
        case let .episode(s, e, _): return (e.url, store.playlist(s.playlistID)?.userAgent)
        case let .file(j): return (IPTVRecorder.shared.fileURL(j).absoluteString, nil)
        }
    }

    private func open(at start: TimeInterval) {
        let (address, ua) = streamURL()
        guard let address, let url = URL(string: address) else { error = "This stream has no address."; return }
        error = nil
        let o = KSOptions()
        o.startPlayTime = start
        o.isAccurateSeek = true
        o.registerRemoteControll = true
        o.autoSelectEmbedSubtitle = false
        if let ua, !ua.isEmpty { o.userAgent = ua }
        if isLive { o.isLive = true }
        o.playerTypes = [KSMEPlayer.self, KSAVPlayer.self]
        if let layer {
            layer.set(url: url, options: o)
        } else {
            let l = KSPlayerLayer(url: url, options: o, delegate: nil)
            l.delegate = self
            layer = l
        }
        audioTracks = []
        subtitles = []
        subtitleID = nil
        layerVersion += 1
    }

    // MARK: - Events

    fileprivate func stateChanged(_ s: KSPlayerState) {
        state = s
        if s == .readyToPlay {
            retries = 0
            status = nil
            layer?.player.contentMode = fit.mode
            if let p = layer?.player { duration = p.duration }
            refreshTracks()
            measureSoon()
        }
        if s == .buffering, isLive { watchStall() } else { stallTask?.cancel() }
        if s == .bufferFinished { status = nil }
    }

    fileprivate func timeChanged(_ t: TimeInterval, _ total: TimeInterval) {
        time = t
        if total > 0 { duration = total }
        if let id = resumeID, Date().timeIntervalSince(lastSave) > 10 {
            lastSave = Date()
            store.savePosition(id, t, duration: duration)
        }
    }

    fileprivate func finished(_ err: Error?) {
        // Live streams drop: reconnect with growing pauses (automatic recovery).
        if isLive || err != nil {
            if retries < 6 {
                retries += 1
                let delay = min(8.0, pow(2.0, Double(retries - 1)))
                status = "Reconnecting… (\(retries))"
                let at = isLive ? 0 : time
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.open(at: at)
                }
                return
            }
            status = nil
            error = err?.localizedDescription ?? "The stream stopped."
            return
        }
        if let id = resumeID { store.savePosition(id, duration, duration: duration) }
        if case let .episode(s, e, all) = kind, let i = all.firstIndex(of: e), let next = all[safe: i + 1] {
            kind = .episode(s, next, all)
            noteWatching()
            time = 0
            open(at: store.position(next.id) ?? 0)
            showOverlay(autoHide: true)
            return
        }
        close()
    }

    /// Remembers the channel's real resolution and sound so it can be found by quality.
    private func measureSoon() {
        guard isLive, let ch = channel else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let p = self.layer?.player, self.channel?.id == ch.id else { return }
            let height = Int(p.naturalSize.height)
            let audioText = [p.audioFormat ?? ""] + p.tracks(mediaType: .audio).filter(\.isEnabled).map(\.name)
            let range = String(describing: p.dynamicRange).lowercased()
            let hdr = range.contains("hdr") || range.contains("hlg") || range.contains("dolby") || range.contains("dovi")
            self.store.recordMeasured(ch, height: height, channels: IPTVMeasured.channels(from: audioText.joined(separator: " ")), hdr: hdr)
        }
    }

    /// A live stream that buffers for 12 s is reopened.
    private func watchStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled, self.state == .buffering, self.isLive else { return }
            self.status = "Reconnecting…"
            self.open(at: 0)
        }
    }

    func retry() {
        retries = 0
        open(at: isLive ? 0 : time)
    }

    // MARK: - Live

    func zap(_ delta: Int) {
        guard isLive, let c = channel, !lineup.isEmpty else { return }
        let i = lineup.firstIndex { $0.id == c.id } ?? 0
        let n = lineup.count
        tune(lineup[((i + delta) % n + n) % n])
    }

    func tune(_ c: IPTVChannel) {
        if let cur = channel, cur.id != c.id { previousChannel = cur }
        kind = .live(c)
        retries = 0
        time = 0
        duration = 0
        open(at: 0)
        panel = nil
        showOverlay(autoHide: true)
    }

    func previous() { if let p = previousChannel { tune(p) } }

    /// Number keys: wait a moment for more digits, then tune.
    func typeDigit(_ d: Int) {
        guard isLive else { return }
        typedNumber += String(d)
        numberTask?.cancel()
        numberTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            if let n = Int(self.typedNumber), let c = self.lineup.first(where: { $0.number == n }) ?? self.lineup[safe: n - 1] { self.tune(c) }
            self.typedNumber = ""
        }
    }

    // MARK: - Transport

    func togglePlay() {
        guard let layer else { return }
        if isPlaying { layer.pause(); showOverlay(autoHide: false) } else { layer.play(); hideSoon() }
    }

    var canSeek: Bool { !isLive && duration > 0 }

    func skip(_ s: TimeInterval) {
        guard canSeek else { return }
        let t = max(0, min(duration - 1, time + s))
        time = t
        layer?.seek(time: t, autoPlay: true)
        showOverlay(autoHide: true)
    }

    func seek(to t: TimeInterval) {
        guard canSeek else { return }
        time = t
        layer?.seek(time: t, autoPlay: true)
    }

    // MARK: - Tracks

    func refreshTracks() {
        guard let layer else { return }
        audioTracks = layer.player.tracks(mediaType: .audio)
        subtitles = layer.subtitleModel.subtitleInfos
    }

    func select(audio t: any MediaPlayerTrack) {
        layer?.player.select(track: t)
        refreshTracks()
    }

    func select(subtitle s: (any SubtitleInfo)?) {
        layer?.select(subtitleInfo: s)
        subtitleID = s?.subtitleID
    }

    // MARK: - Overlay

    func showOverlay(autoHide: Bool) {
        overlayVisible = true
        hideTask?.cancel()
        if autoHide { hideSoon() }
    }

    func hideSoon() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.isPlaying, self.panel == nil else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.overlayVisible = false }
        }
    }

    func close() {
        if let id = resumeID { store.savePosition(id, time, duration: duration) }
        hideTask?.cancel()
        stallTask?.cancel()
        layer?.delegate = nil
        layer?.stop()
        onClose?()
    }
}

extension IPTVPlayerController: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) { stateChanged(state) }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) { timeChanged(currentTime, totalTime) }
    func player(layer: KSPlayerLayer, finish error: Error?) { finished(error) }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

// MARK: - Screen

extension View {
    /// Shows the IPTV player over everything, and due programme reminders.
    @ViewBuilder func iptvPresentation(_ presenter: IPTVPlayerPresenter, store: IPTVStore) -> some View {
        let reminder = Binding<Bool>(get: { store.dueReminder != nil }, set: { if !$0 { store.dueReminder = nil } })
        #if os(macOS)
        ZStack {
            self
            if let req = presenter.request {
                IPTVPlayerScreen(request: req).id(req.id).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: presenter.request?.id)
        .alert(store.dueReminder?.title ?? "", isPresented: reminder, presenting: store.dueReminder) { r in
            Button("Watch") { if let ch = store.channel(r.channelID) { presenter.live(ch, lineup: store.channels) } }
            Button("Dismiss", role: .cancel) {}
        } message: { r in Text("Starting now on \(r.channelName)") }
        #else
        fullScreenCover(item: Binding(get: { presenter.request }, set: { presenter.request = $0 })) { req in
            IPTVPlayerScreen(request: req)
        }
        .alert(store.dueReminder?.title ?? "", isPresented: reminder, presenting: store.dueReminder) { r in
            Button("Watch") { if let ch = store.channel(r.channelID) { presenter.live(ch, lineup: store.channels) } }
            Button("Dismiss", role: .cancel) {}
        } message: { r in Text("Starting now on \(r.channelName)") }
        #endif
    }
}

struct IPTVPlayerScreen: View {
    @StateObject private var c: IPTVPlayerController
    @ObservedObject private var store = IPTVStore.shared
    let request: IPTVPlayerPresenter.Request
    @FocusState private var rootFocused: Bool

    init(request: IPTVPlayerPresenter.Request) {
        self.request = request
        _c = StateObject(wrappedValue: IPTVPlayerController(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if c.layer != nil {
                IPTVLayerView(controller: c).id(c.layerVersion >= 0 ? 0 : 1).ignoresSafeArea()
            }
            if c.state == .preparing || c.state == .buffering {
                ProgressView().scaleEffect(1.5)
            }
            if let s = c.status {
                Text(s).font(.headline).padding(20.s).background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 80.s)
            }
            if let err = c.error {
                VStack(spacing: 20.s) {
                    Text(err).multilineTextAlignment(.center)
                    Text(Platform.isTV ? "Click to try again" : "Tap to try again").font(.caption).foregroundStyle(.secondary)
                }
                .padding(30.s).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16.s))
            }
            input
            if c.overlayVisible || c.panel != nil {
                IPTVInfoBar(c: c).transition(.opacity).allowsHitTesting(!Platform.isTV)
            }
            if !c.typedNumber.isEmpty {
                Text(c.typedNumber).font(.system(size: 90.s, weight: .bold, design: .rounded))
                    .padding(30.s).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20.s))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(60.s)
            }
            if c.panel == .channels {
                IPTVChannelPanel(c: c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if c.panel == .tracks {
                IPTVTrackPanel(c: c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: c.panel)
        .animation(.easeInOut(duration: 0.3), value: c.overlayVisible)
        .onPlayPause { c.togglePlay() }
        .onBack(perform: back)
        .onAppear {
            c.onClose = { IPTVPlayerPresenter.shared.close() }
            c.start()
            rootFocused = true
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onChange(of: c.panel) { _, p in if p == nil { rootFocused = true } }
        .onDisappear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }

    /// Siri Remote: ▲▼ change channel (live) · ◀ channel list · ▶ audio and subtitles · click shows the info bar.
    /// Films: ◀▶ skip · ▼ audio and subtitles · click pauses. Keyboard: the same with the arrow keys and digits.
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
                if c.error != nil { c.retry(); return }
                if c.panel != nil { c.panel = nil; c.hideSoon(); return }
                if c.overlayVisible && c.isPlaying { withAnimation { c.overlayVisible = false } } else { c.showOverlay(autoHide: c.isPlaying) }
            }
            .onContinuousHover { phase in
                if case .active = phase, !c.overlayVisible { c.showOverlay(autoHide: c.isPlaying) }
            }
            .onKeyPress(.space) { c.togglePlay(); return .handled }
            .onKeyPress(.return) { select(); return .handled }
            .onKeyPress(.leftArrow) { move(.left); return .handled }
            .onKeyPress(.rightArrow) { move(.right); return .handled }
            .onKeyPress(.upArrow) { move(.up); return .handled }
            .onKeyPress(.downArrow) { move(.down); return .handled }
            .onKeyPress(.escape) { back(); return .handled }
            .onKeyPress(characters: .decimalDigits) { press in
                if let d = Int(press.characters) { c.typeDigit(d) }
                return .handled
            }
        #endif
    }

    private func select() {
        if c.error != nil { c.retry(); return }
        if c.isLive {
            if c.overlayVisible { withAnimation { c.overlayVisible = false } } else { c.showOverlay(autoHide: true) }
        } else {
            c.togglePlay()
        }
    }

    private func move(_ d: MoveCommandDirection) {
        if c.isLive {
            switch d {
            case .up: c.zap(-1)
            case .down: c.zap(1)
            case .left: c.panel = .channels; c.showOverlay(autoHide: false)
            case .right: c.panel = .tracks; c.refreshTracks(); c.showOverlay(autoHide: false)
            @unknown default: break
            }
            return
        }
        switch d {
        case .left: c.skip(-Double(AppSettings.shared.skipBack))
        case .right: c.skip(Double(AppSettings.shared.skipForward))
        case .up: c.showOverlay(autoHide: c.isPlaying)
        case .down: c.panel = .tracks; c.refreshTracks(); c.showOverlay(autoHide: false)
        @unknown default: break
        }
    }

    private func back() {
        if c.panel != nil { c.panel = nil; c.hideSoon(); return }
        if c.overlayVisible && c.isPlaying { withAnimation { c.overlayVisible = false }; return }
        c.close()
    }
}

/// Hosts the player's view.
#if os(macOS)
struct IPTVLayerView: NSViewRepresentable {
    @ObservedObject var controller: IPTVPlayerController
    func makeNSView(context: Context) -> NSView { controller.layer?.makeUIView() ?? NSView() }
    func updateNSView(_ view: NSView, context: Context) { controller.layer?.updateUIView(view) }
}
#else
struct IPTVLayerView: UIViewRepresentable {
    @ObservedObject var controller: IPTVPlayerController
    func makeUIView(context: Context) -> UIView { controller.layer?.makeUIView() ?? UIView() }
    func updateUIView(_ view: UIView, context: Context) { controller.layer?.updateUIView(view) }
}
#endif

/// Bottom bar: channel and what's on (live), or title and timeline (catch-up, films, episodes). On touch screens
/// and the Mac it carries the buttons too.
struct IPTVInfoBar: View {
    @ObservedObject var c: IPTVPlayerController
    @ObservedObject private var store = IPTVStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(spacing: 0) {
                #if !os(tvOS)
                HStack(spacing: 22) {
                    control("xmark") { c.close() }
                    Spacer()
                    if c.isLive {
                        control("list.bullet") { c.panel = c.panel == .channels ? nil : .channels }
                        control("chevron.up") { c.zap(-1) }
                        control("chevron.down") { c.zap(1) }
                    }
                    control("captions.bubble") { c.refreshTracks(); c.panel = c.panel == .tracks ? nil : .tracks }
                    #if os(iOS)
                    RoutePicker().frame(width: 44, height: 44)
                    #endif
                }
                .padding(.top, 60.s).padding(.horizontal, 60.s)
                #endif
                Spacer()
                VStack(alignment: .leading, spacing: 16.s) {
                    if c.isLive, let ch = c.channel { liveInfo(ch, now: ctx.date) } else { vodInfo }
                }
                .padding(40.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func liveInfo(_ ch: IPTVChannel, now: Date) -> some View {
        let (cur, next) = store.nowNext(ch, at: now)
        HStack(alignment: .center, spacing: 30.s) {
            ChannelLogo(channel: ch, size: 120.s)
            VStack(alignment: .leading, spacing: 8.s) {
                HStack(spacing: 14.s) {
                    if let n = ch.number { Text("\(n)").font(.title3.monospacedDigit()).foregroundStyle(.secondary) }
                    Text(ch.name).font(.title2.bold()).lineLimit(1)
                    Text("LIVE").font(.caption2.bold()).padding(.horizontal, 10.s).padding(.vertical, 3.s).background(.red, in: Capsule())
                    if ch.hasCatchup { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                    if IPTVRecorder.shared.isRecording(channel: ch) != nil {
                        Label("REC", systemImage: "record.circle").font(.caption2.bold()).foregroundStyle(.red)
                    }
                    ForEach(store.tags(ch).sorted { $0.rawValue < $1.rawValue }) { QualityBadge(tag: $0) }
                }
                if let cur {
                    Text(cur.title).font(.headline).lineLimit(1)
                    HStack(spacing: 14.s) {
                        Text(cur.timeRange).font(.caption).foregroundStyle(.secondary)
                        ProgressBar(value: cur.progress(at: now)).frame(width: 360.s)
                    }
                } else {
                    Text("No guide information").font(.callout).foregroundStyle(.secondary)
                }
                if let next { Text("Next: \(IPTVFormat.time(next.start))  \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(IPTVFormat.time(now)).font(.title3.monospacedDigit())
        }
        if Platform.isTV, c.panel == nil {
            Text("▲▼ channels   ◀ channel list   ▶ audio & subtitles").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var vodInfo: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(c.title).font(.title2.bold()).lineLimit(1)
            if case let .catchup(ch, p) = c.kind { Text("\(ch.name) · \(IPTVFormat.day(p.start)) \(p.timeRange)").font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
        if c.duration > 0 {
            ProgressBar(value: c.time / max(1, c.duration))
            HStack {
                Text(formatTime(c.time)); Spacer(); Text("-" + formatTime(max(0, c.duration - c.time)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        #if !os(tvOS)
        HStack(spacing: 50) {
            Spacer()
            control("gobackward.\(AppSettings.shared.skipBack)") { c.skip(-Double(AppSettings.shared.skipBack)) }
            control(c.isPlaying ? "pause.fill" : "play.fill") { c.togglePlay() }
            control("goforward.\(AppSettings.shared.skipForward)") { c.skip(Double(AppSettings.shared.skipForward)) }
            Spacer()
        }
        #endif
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(width: 46, height: 46)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 6.s)
    }
}

/// The lineup the channel was picked from, with what's on now.
struct IPTVChannelPanel: View {
    @ObservedObject var c: IPTVPlayerController
    @ObservedObject private var store = IPTVStore.shared
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Channels").font(.title3.bold()).padding(30.s)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6.s) {
                        ForEach(c.lineup) { ch in
                            Button { c.tune(ch) } label: {
                                HStack(spacing: 18.s) {
                                    ChannelLogo(channel: ch, size: 64.s)
                                    VStack(alignment: .leading, spacing: 4.s) {
                                        Text(ch.number.map { "\($0)  \(ch.name)" } ?? ch.name).font(.callout.bold()).lineLimit(1)
                                        Text(store.nowNext(ch).0?.title ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if ch.id == c.channel?.id { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                                }
                                .padding(.horizontal, 20.s).padding(.vertical, 10.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PanelRowStyle())
                            .focused($focused, equals: ch.id)
                            .id(ch.id)
                        }
                    }
                    .padding(.horizontal, 20.s)
                }
                .onAppear {
                    if let id = c.channel?.id { proxy.scrollTo(id, anchor: .center); focused = id }
                }
            }
        }
        .frame(width: 680.s)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .tvFocusSection()
    }
}

/// Audio, subtitles and picture fit.
struct IPTVTrackPanel: View {
    @ObservedObject var c: IPTVPlayerController
    @ObservedObject private var recorder = IPTVRecorder.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10.s) {
                Text("Audio").font(.title3.bold()).padding(.top, 30.s)
                if c.audioTracks.isEmpty { Text("Only one track").foregroundStyle(.secondary) }
                ForEach(Array(c.audioTracks.enumerated()), id: \.offset) { _, t in
                    row(t.name.isEmpty ? "Track \(t.trackID)" : t.name, selected: t.isEnabled) { c.select(audio: t) }
                }
                Text("Subtitles").font(.title3.bold()).padding(.top, 20.s)
                row("Off", selected: c.subtitleID == nil) { c.select(subtitle: nil) }
                ForEach(Array(c.subtitles.enumerated()), id: \.offset) { _, s in
                    row(s.name, selected: c.subtitleID == s.subtitleID) { c.select(subtitle: s) }
                }
                if c.isLive, let ch = c.channel {
                    Text("Record").font(.title3.bold()).padding(.top, 20.s)
                    if let job = recorder.isRecording(channel: ch) {
                        row("Stop recording", selected: false) { recorder.stop(job.id) }
                    } else {
                        if let now = IPTVStore.shared.nowNext(ch).0 {
                            row("Record “\(now.title)”", selected: false) { recorder.record(ch, programme: now); c.panel = nil }
                        }
                        row("Record the next hour", selected: false) { recorder.record(ch, minutes: 60); c.panel = nil }
                    }
                }
                Text("Picture").font(.title3.bold()).padding(.top, 20.s)
                ForEach(PlayerController.Fit.allCases) { f in
                    row(f.label, selected: c.fit == f) { c.fit = f }
                }
            }
            .padding(.horizontal, 30.s).padding(.bottom, 40.s)
        }
        .frame(width: 600.s)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .tvFocusSection()
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 20.s).padding(.vertical, 12.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
    }
}

/// A list row that highlights on focus (Apple TV, keyboard) and on press.
struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }
    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? .black : .white)
                .background(RoundedRectangle(cornerRadius: 12.s).fill(focused ? .white : configuration.isPressed ? .white.opacity(0.2) : .clear))
                .scaleEffect(focused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
                .contentShape(Rectangle())
        }
    }
}

/// A channel's logo from the playlist or the TV guide. Shows the channel's initials until it loads, and when there is
/// none or it fails.
struct ChannelLogo: View {
    let channel: IPTVChannel
    var size: CGFloat
    @ObservedObject private var store = IPTVStore.shared
    @State private var image: UIImage?

    var body: some View {
        let url = store.logo(channel).flatMap { URL(string: $0) }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16).fill(.white.opacity(image == nil ? 0.08 : 0.04))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding(size * 0.1)
            } else {
                Text(channel.name.channelInitials).font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, size * 0.08)
            }
        }
        .frame(width: size * 1.4, height: size)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageCache.shared.cached(url) { image = c; return }
            image = nil
            image = await ImageCache.shared.load(url)
        }
    }
}
