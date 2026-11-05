import AVFoundation
import Combine
#if KSPLAYER
import KSPlayer
#endif
import SwiftUI

/// KSPlayer options with the app's track choices and display matching.
final class PlayerOptions: KSOptions {
    /// Container stream index (Plex `index`) of the audio track to open with.
    var wantedAudioIndex: Int?
    var matchDisplay = true

    override func wantedAudio(tracks: [any MediaPlayerTrack]) -> (any MediaPlayerTrack)? {
        if let i = wantedAudioIndex, let t = tracks.first(where: { Int($0.trackID) == i }) { return t }
        return super.wantedAudio(tracks: tracks)
    }

    /// Switches the TV to the video's frame rate and dynamic range (Apple TV "Match Content").
    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {
        if matchDisplay { super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription) }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    enum Panel: String, CaseIterable, Identifiable { case tracks, chapters, picture, info
        var id: String { rawValue }
        var title: String { self == .tracks ? "Audio & Subtitles" : rawValue.capitalized }
    }
    enum Fit: String, CaseIterable, Identifiable { case fit, fill, stretch
        var id: String { rawValue }
        var label: String { ["fit": "Original", "fill": "Zoom to fill", "stretch": "Stretch"][rawValue]! }
        #if os(macOS)
        var mode: UIViewContentMode { [.fit: .scaleAspectFit, .fill: .scaleAspectFill, .stretch: .scaleToFill][self]! }
        #else
        var mode: UIView.ContentMode { [.fit: .scaleAspectFit, .fill: .scaleAspectFill, .stretch: .scaleToFill][self]! }
        #endif
    }

    @Published private(set) var item: PlexItem
    @Published private(set) var plan: Decide.Plan
    @Published private(set) var state: KSPlayerState = .preparing
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var overlayVisible = true
    @Published var panel: Panel?
    @Published private(set) var scrubTime: TimeInterval?
    @Published private(set) var introMarker: PlexMarker?
    @Published private(set) var upNext: PlexItem?
    @Published private(set) var upNextCountdown = 10
    @Published private(set) var error: String?
    /// A passing message (a subtitle that couldn't load) while playback carries on.
    @Published private(set) var notice: String?
    /// ◀ ▶ presses while playing add up here and seek once (shown as "+90 s").
    @Published private(set) var pendingSkip: TimeInterval?
    /// The Siri Remote's touch surface is moving the scrub head.
    @Published private(set) var touchScrubbing = false
    /// The subtitle delay row takes ◀ ▶ (Apple TV).
    @Published var adjustingDelay = false
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var rate: Float = 1
    @Published var fit: Fit = .fit { didSet { layer?.player.contentMode = fit.mode } }
    @Published private(set) var selectedOnlineSubtitle: String?
    @Published private(set) var playerSubtitles: [any SubtitleInfo] = []
    @Published private(set) var layerVersion = 0

    private(set) var layer: KSPlayerLayer?
    private(set) var bif: BIF?
    private var settings: AppSettings { .shared }
    private var lastReport = Date.distantPast
    private var hideTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var scrubStep: TimeInterval = 10
    private var lastScrubMove = Date.distantPast
    private var skipTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var touchScrubAnchor: TimeInterval = 0
    private var touchScrubEnded = Date.distantPast
    private var lastNowPlaying = Date.distantPast
    private var upNextDismissed = false
    private var introSkipped = Set<Double>()
    private var nextEpisode: PlexItem?
    private var nextLoaded = false
    private var transcodeSession: String?
    private var appliedSubtitle = false
    private var openRetries = 0
    private var show: PlexItem?
    private var cancellables: Set<AnyCancellable> = []
    var onClose: (() -> Void)?

    init(item: PlexItem, mediaIndex: Int?, audioId: Int?, subtitleId: Int??) {
        self.item = item
        let mem = TitleMemory.shared.record(item)
        let sub: Int?? = subtitleId ?? mem.subtitleId.map { $0 < 0 ? nil : $0 }
        plan = Decide.plan(item, mediaIndex: mediaIndex ?? mem.mediaIndex ?? 0, audioId: audioId ?? mem.audioId, subtitleId: sub, settings: AppSettings.shared)
        selectedOnlineSubtitle = subtitleId == nil ? mem.onlineSubtitle : nil
    }

    // MARK: - Opening

    func start(at startAt: TimeInterval?) {
        let start = startAt ?? TitleMemory.shared.resumePosition(item)
        activateNowPlaying()
        open(at: start)
        Task { await loadExtras() }
        hideOverlaySoon()
    }

    private func makeOptions(start: TimeInterval) -> PlayerOptions {
        let o = PlayerOptions()
        o.startPlayTime = start
        o.wantedAudioIndex = plan.audio?.index
        o.matchDisplay = settings.matchFrameRate
        o.autoSelectEmbedSubtitle = false
        o.isAccurateSeek = true
        // The app publishes Now Playing and handles the remote commands itself (NowPlaying), with its skip settings.
        o.registerRemoteControll = false
        switch plan.engine {
        case .ffmpeg: o.playerTypes = [KSMEPlayer.self]
        case .apple, .appleRemux: o.playerTypes = [KSAVPlayer.self, KSMEPlayer.self]
        }
        return o
    }

    private func playbackURL(start: TimeInterval) -> (URL?, TimeInterval) {
        let pc = PlexClient.shared
        if plan.engine == .appleRemux {
            let session = UUID().uuidString
            transcodeSession = session
            remuxOffset = start
            // The server starts the stream at the offset, so the player starts at 0.
            return (pc.remuxURL(item, mediaIndex: plan.mediaIndex, offset: start, session: session, h264Only: remuxH264), 0)
        }
        return (plan.part.flatMap(pc.directPlayURL), start)
    }

    private func open(at start: TimeInterval) {
        applySubtitleStyle()
        let (url, playerStart) = playbackURL(start: start)
        guard let url else { error = "This item has no playable file."; return }
        error = nil
        appliedSubtitle = false
        let options = makeOptions(start: playerStart)
        if let layer {
            layer.set(url: url, options: options)
        } else {
            let l = KSPlayerLayer(url: url, options: options, delegate: nil)
            l.delegate = self
            layer = l
            l.subtitleModel.$subtitleInfos
                .receive(on: DispatchQueue.main)
                .sink { [weak self] infos in self?.playerSubtitles = infos }
                .store(in: &cancellables)
        }
        layerVersion += 1
    }

    private func loadExtras() async {
        await loadBIF()
        if item.type == "episode", let sk = item.grandparentRatingKey { show = try? await PlexClient.shared.metadata(sk) }
    }

    private func loadBIF() async {
        let part = plan.part
        guard let part, let data = await PlexClient.shared.previewIndex(part) else { return }
        if plan.part?.id == part.id { bif = BIF(data) }
    }

    // MARK: - Delegate events

    private func stateChanged(_ s: KSPlayerState) {
        state = s
        if s == .readyToPlay {
            openRetries = 0
            duration = layer?.player.duration ?? duration
            layer?.player.contentMode = fit.mode
            applyTracksAfterOpen()
        }
        if s == .paused || s == .buffering { reportTimeline(force: true) }
        publishNowPlaying()
    }

    private func timeChanged(_ current: TimeInterval, _ total: TimeInterval) {
        let offset = plan.engine == .appleRemux ? remuxOffset : 0
        time = current + offset
        if total > 0 { duration = total + offset }
        if duration <= 0, let d = item.durationMs { duration = Double(d) / 1000 }
        reportTimeline(force: false)
        checkMarkers()
        if Date().timeIntervalSince(lastNowPlaying) > 5 { publishNowPlaying() }
    }
    private var remuxOffset: TimeInterval = 0
    /// Last resort on iPhone/iPad when AVPlayer refuses the server's HEVC stream.
    private var remuxH264 = false

    private func finished(_ err: Error?) {
        if let err {
            // A first open can fail while the server is still starting the stream (or waking a disk): try the same
            // way once more before changing anything.
            if openRetries < 1 {
                openRetries += 1
                let at = time
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.open(at: at)
                }
                return
            }
            // Without the FFmpeg player (iPhone, iPad), a file AVPlayer can't open directly goes through the server.
            if !Platform.hasFFmpeg, plan.engine == .apple {
                openRetries = 0
                plan.engine = .appleRemux
                plan.note = "AVPlayer couldn't open the file directly; the server repackages it as HLS."
                open(at: time)
                return
            }
            if !Platform.hasFFmpeg, plan.engine == .appleRemux, !remuxH264 {
                openRetries = 0
                remuxH264 = true
                plan.note = "AVPlayer refused the server's HEVC stream; the server converts the video to H.264 (SDR) instead."
                if let s = transcodeSession { Task { await PlexClient.shared.stopTranscode(s) } }
                open(at: time)
                return
            }
            // If Apple's player still can't open it, fall back to the app's own player.
            if Platform.hasFFmpeg, plan.engine != .ffmpeg {
                openRetries = 0
                plan.engine = .ffmpeg
                plan.note = "Apple's player couldn't open this file; playing it with the app's player."
                open(at: time)
                return
            }
            error = err.localizedDescription
            return
        }
        Task { await PlexClient.shared.setWatched(item, true) }
        TitleMemory.shared.savePosition(item, duration, duration: duration)
        if item.type == "episode", settings.autoplayNext, let next = nextEpisode {
            play(next)
        } else {
            close()
        }
    }

    // MARK: - Tracks

    private func applyTracksAfterOpen() {
        guard !appliedSubtitle, let layer else { return }
        appliedSubtitle = true
        // KSPlayer's AVPlayer engine opens the wanted track itself; the AVPlayer-only build picks it here.
        if let a = plan.audio, plan.engine == .ffmpeg || (!Platform.hasFFmpeg && plan.engine == .apple) { selectAudioTrack(a, in: layer) }
        if let online = selectedOnlineSubtitle, let url = Online.shared.cachedSubtitle(online) {
            addAndSelect(URLSubtitleInfo(subtitleID: "online-\(online)", name: "Downloaded", url: url, languageCode: nil))
        } else if let s = plan.subtitle {
            Task { await select(subtitle: s) }
        } else {
            layer.select(subtitleInfo: nil)
        }
        layer.subtitleModel.subtitleDelay = subtitleDelay
    }

    private func selectAudioTrack(_ s: PlexStream, in layer: KSPlayerLayer) {
        let tracks = layer.player.tracks(mediaType: .audio)
        let embedded = plan.part?.audioStreams ?? []
        let match = tracks.first { Int($0.trackID) == s.index }
            ?? embedded.firstIndex(where: { $0.id == s.id }).flatMap { tracks[safe: $0] }
        if let match, !match.isEnabled { layer.player.select(track: match) }
    }

    func chooseAudio(_ s: PlexStream) {
        TitleMemory.shared.update(item) { $0.audioId = s.id }
        if let pid = plan.part?.id { Task { await PlexClient.shared.selectStreams(partId: pid, audio: s.id, subtitle: nil) } }
        let previous = plan
        plan = Decide.plan(item, mediaIndex: plan.mediaIndex, audioId: s.id, subtitleId: .some(plan.subtitle?.id), settings: settings)
        if plan.engine != previous.engine || plan.engine == .appleRemux {
            open(at: time)  // different player needed: reopen at the same point
        } else if let layer {
            selectAudioTrack(s, in: layer)
        }
    }

    /// Picks a Plex subtitle stream: embedded tracks come from the player, external files are fetched from Plex.
    func select(subtitle s: PlexStream?) async {
        TitleMemory.shared.update(item) { $0.subtitleId = s?.id ?? -1; $0.onlineSubtitle = nil }
        selectedOnlineSubtitle = nil
        plan.subtitle = s
        if let pid = plan.part?.id { Task { await PlexClient.shared.selectStreams(partId: pid, audio: nil, subtitle: s?.id ?? 0) } }
        guard let layer else { return }
        guard let s else { layer.select(subtitleInfo: nil); return }
        if Platform.hasFFmpeg, !s.isExternal, let idx = s.index {
            let infos = layer.subtitleModel.subtitleInfos.filter { !($0 is URLSubtitleInfo) }
            let embedded = (plan.part?.subtitleStreams ?? []).filter { !$0.isExternal }
            let info = infos.first { $0.subtitleID == String(idx) }
                ?? embedded.firstIndex(where: { $0.id == s.id }).flatMap { infos[safe: $0] }
            layer.select(subtitleInfo: info)
            return
        }
        // External files, and on iPhone/iPad embedded text tracks too, come from the server as files.
        guard let url = PlexClient.shared.subtitleURL(s) ?? PlexClient.shared.streamFileURL(s) else { return }
        if !Platform.hasFFmpeg, Decide.isImageSub(s) {
            show(notice: "Image subtitles (PGS/VobSub) can't be shown on this device. Search online in Subtitles for a text version."
            return
        }
        do {
            let local = try await downloadPlexSubtitle(url, stream: s)
            addAndSelect(URLSubtitleInfo(subtitleID: "plex-\(s.id)", name: s.extendedDisplayTitle, url: local, languageCode: s.languageCode))
        } catch {
            show(notice: "Couldn't load the subtitle: \(error.localizedDescription)")
        }
    }

    /// External Plex subtitles are saved with their real extension so the parser recognises the format.
    private func downloadPlexSubtitle(_ url: URL, stream: PlexStream) async throws -> URL {
        let ext = ["subrip": "srt", "srt": "srt", "ass": "ass", "ssa": "ssa", "vtt": "vtt", "webvtt": "vtt", "pgs": "sup"][stream.codec] ?? stream.codec
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plex-subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(stream.id).\(ext.isEmpty ? "srt" : ext)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let data = try await PlexClient.shared.request("GET", url, accept: "*/*")
        try data.write(to: file, options: .atomic)
        return file
    }

    private func addAndSelect(_ info: URLSubtitleInfo) {
        guard let layer else { return }
        if let existing = layer.subtitleModel.subtitleInfos.first(where: { $0.subtitleID == info.subtitleID }) {
            layer.select(subtitleInfo: existing)
        } else {
            layer.subtitleModel.addSubtitle(info: info)
            layer.select(subtitleInfo: info)
        }
    }

    func useOnlineSubtitle(_ fileURL: URL, title: String) {
        let name = fileURL.lastPathComponent
        selectedOnlineSubtitle = name
        plan.subtitle = nil
        TitleMemory.shared.update(item) { $0.onlineSubtitle = name; $0.subtitleId = nil }
        addAndSelect(URLSubtitleInfo(subtitleID: "online-\(name)", name: title, url: fileURL, languageCode: nil))
    }

    func adjustSubtitleDelay(_ d: Double) {
        subtitleDelay = (subtitleDelay + d).rounded(toPlaces: 1)
        layer?.subtitleModel.subtitleDelay = subtitleDelay
    }

    func setRate(_ r: Float) {
        rate = r
        layer?.player.playbackRate = r
        publishNowPlaying()
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation { self.notice = nil }
        }
    }

    // MARK: - Versions and errors

    var hasOtherVersions: Bool { item.media.count > 1 }

    /// Plays another file of the same title from the same point, keeping the audio and subtitle languages.
    func switchVersion(_ index: Int) {
        guard item.media.indices.contains(index), index != plan.mediaIndex || error != nil else { return }
        let at = time
        TitleMemory.shared.update(item) { $0.mediaIndex = index }
        if let s = transcodeSession { Task { await PlexClient.shared.stopTranscode(s) } }
        plan = carryLanguages(item, mediaIndex: index)
        bif = nil; remuxOffset = 0; remuxH264 = false; openRetries = 0
        selectedOnlineSubtitle = nil
        open(at: at)
        Task { await loadBIF() }
        showOverlay(autoHide: true)
    }

    /// The version after the current one (for the error screen).
    func tryOtherVersion() {
        guard hasOtherVersions else { return }
        switchVersion((plan.mediaIndex + 1) % item.media.count)
    }

    /// Opens the same file again from where it stopped.
    func retry() {
        openRetries = 0
        if let s = transcodeSession { Task { await PlexClient.shared.stopTranscode(s) } }
        open(at: time)
    }

    /// A plan for an item (or another version of it) with the current audio and subtitle languages.
    private func carryLanguages(_ next: PlexItem, mediaIndex: Int = 0) -> Decide.Plan {
        let subLang = plan.subtitle?.languageCode
        let audioLang = plan.audio?.languageCode
        var p = Decide.plan(next, mediaIndex: mediaIndex, settings: settings)
        if let audioLang, let a = p.part?.audioStreams.first(where: { Decide.sameLang($0.languageCode, audioLang) }), p.audio?.languageCode != a.languageCode {
            p = Decide.plan(next, mediaIndex: mediaIndex, audioId: a.id, settings: settings)
        }
        if let subLang, let s = p.part?.subtitleStreams.first(where: { Decide.sameLang($0.languageCode, subLang) && !$0.forced }) {
            p = Decide.plan(next, mediaIndex: mediaIndex, audioId: p.audio?.id, subtitleId: .some(s.id), settings: settings)
        }
        return p
    }

    #if KSPLAYER
    /// KSPlayer's own defaults, scaled by the size and position settings.
    private static let baseFontSize = KSOptions.subtitleFontSize
    private static let baseMargin = KSOptions.textPosition.verticalMargin
    #endif

    /// Subtitle look from Settings, applied to KSPlayer's renderer. (The AVPlayer build reads Settings as it draws.)
    func applySubtitleStyle() {
        #if KSPLAYER
        let s = settings
        KSOptions.subtitleFontSize = Self.baseFontSize * s.subtitleSize
        KSOptions.textColor = s.subtitleColor.color
        switch s.subtitleStyle {
        case .outline:
            KSOptions.textStrokeColor = .black; KSOptions.textStrokeWidth = 3
            KSOptions.textBackgroundColor = .clear; KSOptions.textShadowColor = .clear
        case .shadow:
            KSOptions.textStrokeWidth = 0; KSOptions.textBackgroundColor = .clear
            KSOptions.textShadowColor = .black; KSOptions.textShadowBlurRadius = 6; KSOptions.textShadowOffset = CGSize(width: 2, height: 2)
        case .box:
            KSOptions.textStrokeWidth = 0; KSOptions.textShadowColor = .clear
            KSOptions.textBackgroundColor = UIColor.black.withAlphaComponent(0.6)
        }
        var pos = KSOptions.textPosition
        pos.verticalMargin = max(Self.baseMargin, 10) * CGFloat(s.subtitleBottomMargin / 0.06)
        KSOptions.textPosition = pos
        #endif
    }

    // MARK: - Transport

    var isPlaying: Bool { state.isPlaying }

    func togglePlay() {
        guard let layer else { return }
        flushSkip()
        if isPlaying { layer.pause(); showOverlay(autoHide: false) } else { layer.play(); hideOverlaySoon() }
    }

    func play() {
        guard let layer, !isPlaying else { return }
        layer.play(); hideOverlaySoon()
    }

    func pause() {
        guard let layer, isPlaying else { return }
        layer.pause(); showOverlay(autoHide: false)
    }

    func seek(to t: TimeInterval) {
        let target = max(0, min(t, max(0, duration - 1)))
        if plan.engine == .appleRemux {
            // A remux stream starts at its offset; re-request it from the new point.
            remuxOffset = target
            if let s = transcodeSession { Task { await PlexClient.shared.stopTranscode(s) } }
            open(at: target)
            return
        }
        time = target
        layer?.seek(time: target, autoPlay: true)
        publishNowPlaying()
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: time + seconds)
        showOverlay(autoHide: true)
    }

    /// ◀ ▶ while playing: presses within ~600 ms add up ("+90 s") and the player seeks once, instead of re-seeking
    /// (and re-buffering) on every press.
    func queueSkip(_ seconds: TimeInterval) {
        let total = (pendingSkip ?? 0) + seconds
        let target = max(0, min(duration > 0 ? duration - 1 : .infinity, time + total))
        pendingSkip = target - time
        showOverlay(autoHide: false)
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushSkip()
        }
    }

    /// Seeks to the accumulated skip now (also before play/pause and clicks).
    func flushSkip() {
        skipTask?.cancel()
        guard let s = pendingSkip else { return }
        pendingSkip = nil
        if abs(s) >= 1 { seek(to: time + s) }
        showOverlay(autoHide: true)
    }

    func cancelSkip() {
        skipTask?.cancel()
        pendingSkip = nil
        hideOverlaySoon()
    }

    /// Where the timeline shows the play head: the scrub head, the accumulated skip target, or the current time.
    var displayTime: TimeInterval {
        if let s = scrubTime { return s }
        if let p = pendingSkip { return max(0, min(duration, time + p)) }
        return time
    }

    // MARK: - Siri Remote touch surface

    /// A horizontal pan on the touch surface scrubs while paused, while scrubbing, or while the timeline is showing.
    var canTouchScrub: Bool {
        panel == nil && error == nil && upNext == nil && pendingSkip == nil && duration > 0
            && (!isPlaying || scrubTime != nil || overlayVisible)
    }

    func beginTouchScrub() {
        flushSkip()
        touchScrubAnchor = scrubTime ?? time
        touchScrubbing = true
        scrub(to: touchScrubAnchor)
    }

    /// `fraction` is the pan's horizontal travel as a share of the surface's width.
    func moveTouchScrub(fraction: Double) {
        // A full swipe covers a third of the title (at least ten minutes), so short swipes give fine control.
        let span = max(600, duration / 3)
        scrub(to: touchScrubAnchor + fraction * span)
    }

    func endTouchScrub() {
        touchScrubbing = false
        touchScrubEnded = Date()
    }

    /// The swipe that moved the scrub head also arrives as a move command when it ends; ignore that one.
    var touchScrubJustEnded: Bool { touchScrubbing || Date().timeIntervalSince(touchScrubEnded) < 0.5 }

    /// While paused (or already scrubbing), ◀ ▶ move a scrub head with preview thumbnails; holding speeds up.
    func scrub(_ direction: Int) {
        let now = Date()
        scrubStep = now.timeIntervalSince(lastScrubMove) < 0.35 ? min(scrubStep * 1.5, 300) : 10
        lastScrubMove = now
        let from = scrubTime ?? time
        scrubTime = max(0, min(duration, from + Double(direction) * scrubStep))
        showOverlay(autoHide: false)
    }

    func commitScrub() {
        if let t = scrubTime { seek(to: t) }
        scrubTime = nil
        touchScrubbing = false
        hideOverlaySoon()
    }

    func cancelScrub() { scrubTime = nil; touchScrubbing = false }

    /// Touch and mouse: dragging the timeline moves the scrub head to a point.
    func scrub(to t: TimeInterval) {
        scrubTime = max(0, min(duration, t))
        showOverlay(autoHide: false)
    }

    func jumpChapter(_ d: Int) {
        let chapters = self.chapters
        guard !chapters.isEmpty else { skip(Double(d) * 60); return }
        if d > 0, let next = chapters.first(where: { $0.start > time + 1 }) { seek(to: next.start) }
        else if d < 0 {
            let prior = chapters.filter { $0.start < time - 3 }
            if let p = prior.last { seek(to: p.start) } else { seek(to: 0) }
        }
        showOverlay(autoHide: true)
    }

    struct Chapter { let title: String; let start: TimeInterval; let thumb: String? }
    var chapters: [Chapter] {
        let plexChapters = item.chapters.map { Chapter(title: $0.title, start: $0.start, thumb: $0.thumb) }
        if !plexChapters.isEmpty { return plexChapters }
        return (layer?.player.chapters ?? []).map { Chapter(title: $0.title, start: $0.start, thumb: nil) }
    }
    var currentChapter: Chapter? { chapters.last { $0.start <= time } }

    func showOverlay(autoHide: Bool) {
        overlayVisible = true
        hideTask?.cancel()
        if autoHide { hideOverlaySoon() }
    }

    func hideOverlaySoon() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.isPlaying, self.panel == nil, self.scrubTime == nil, self.pendingSkip == nil else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.overlayVisible = false }
        }
    }

    // MARK: - Intro, credits, Up Next

    private func checkMarkers() {
        let intro = item.markers.first { $0.isIntro && time >= $0.start && time < $0.end - 1 }
        if let intro, settings.autoSkipIntro, !introSkipped.contains(intro.start) {
            introSkipped.insert(intro.start)
            seek(to: intro.end)
            return
        }
        if introMarker?.start != intro?.start { withAnimation { introMarker = intro } }

        guard item.type == "episode", duration > 0 else { return }
        let credits = item.markers.first { $0.isCredits && $0.start > duration * 0.5 }
        let upNextAt = credits?.start ?? max(0, duration - 30)
        if time >= upNextAt - 15, !nextLoaded {
            nextLoaded = true
            Task { nextEpisode = await PlexClient.shared.nextEpisode(after: item) }
        }
        if time >= upNextAt, upNext == nil, !upNextDismissed, let next = nextEpisode, settings.autoplayNext {
            if settings.autoSkipCredits, credits != nil { play(next); return }
            withAnimation { upNext = next }
            startCountdown()
        }
    }

    func skipIntro() {
        guard let m = introMarker else { return }
        introSkipped.insert(m.start)
        seek(to: m.end)
        introMarker = nil
    }

    private func startCountdown() {
        upNextCountdown = 10
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self, self.upNextCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if self.isPlaying { self.upNextCountdown -= 1 }
            }
            if let self, let next = self.upNext { self.play(next) }
        }
    }

    func dismissUpNext() {
        countdownTask?.cancel()
        upNextDismissed = true
        withAnimation { upNext = nil }
    }

    func playUpNext() { if let n = upNext { play(n) } }

    /// Plays another item in the same player. The subtitle language carries over to the next episode.
    func play(_ next: PlexItem) {
        countdownTask?.cancel()
        skipTask?.cancel(); pendingSkip = nil
        saveProgress(stopped: true)
        plan = carryLanguages(next)
        item = next
        upNext = nil; upNextDismissed = false; nextEpisode = nil; nextLoaded = false
        introMarker = nil; introSkipped = []; bif = nil; time = 0; remuxOffset = 0; remuxH264 = false
        duration = Double(next.durationMs ?? 0) / 1000
        selectedOnlineSubtitle = nil
        publishNowPlaying()
        NowPlaying.shared.setArtwork(owner: self, url: artworkURL)
        open(at: TitleMemory.shared.resumePosition(next))
        Task { await loadExtras() }
        showOverlay(autoHide: true)
    }

    // MARK: - Progress

    private func reportTimeline(force: Bool) {
        guard force || Date().timeIntervalSince(lastReport) > 10, duration > 0 else { return }
        lastReport = Date()
        let st = isPlaying ? "playing" : state == .buffering ? "buffering" : "paused"
        let (it, t, d) = (item, time, duration)
        TitleMemory.shared.savePosition(it, t, duration: d)
        Task { await PlexClient.shared.timeline(it, state: st, time: t, duration: d) }
    }

    private func saveProgress(stopped: Bool) {
        guard duration > 0 else { return }
        let (it, t, d) = (item, time, duration)
        TitleMemory.shared.savePosition(it, t, duration: d)
        TitleMemory.shared.flush()
        Task { await PlexClient.shared.timeline(it, state: stopped ? "stopped" : "paused", time: t, duration: d) }
        if let s = transcodeSession { Task { await PlexClient.shared.stopTranscode(s) } }
    }

    func close() {
        saveProgress(stopped: true)
        countdownTask?.cancel()
        hideTask?.cancel()
        skipTask?.cancel()
        noticeTask?.cancel()
        NowPlaying.shared.clear(owner: self)
        layer?.delegate = nil
        layer?.stop()
        onClose?()
    }

    // MARK: - Now Playing

    private var artworkURL: URL? { PlexClient.shared.imageURL(item.thumb ?? item.posterPath, width: 600, height: 600) }

    private func activateNowPlaying() {
        NowPlaying.shared.activate(owner: self, handlers: .init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            skip: { [weak self] s in self?.skip(s) },
            seek: { [weak self] t in self?.seek(to: t); self?.showOverlay(autoHide: true) }
        ))
        publishNowPlaying()
        NowPlaying.shared.setArtwork(owner: self, url: artworkURL)
    }

    private func publishNowPlaying() {
        lastNowPlaying = Date()
        let episode = item.type == "episode"
        let title = item.title
        let subtitle = episode ? [item.grandparentTitle, item.episodeLabel].compactMap { $0 }.joined(separator: " · ") : item.year.map(String.init)
        NowPlaying.shared.update(owner: self, .init(title: title, subtitle: subtitle, duration: duration, elapsed: time,
                                                    rate: isPlaying ? rate : 0))
    }

    // MARK: - Info

    var showItem: PlexItem? { show }
    var videoInfo: String {
        guard let p = layer?.player else { return "" }
        var parts: [String] = []
        let size = p.naturalSize
        if size.width > 0 { parts.append("\(Int(size.width))×\(Int(size.height))") }
        if let f = p.videoFormat { parts.append(f) }
        if let r = p.dynamicRange { parts.append("\(r)") }
        parts.append(String(format: "%.3f fps", p.nominalFrameRate))
        return parts.joined(separator: " · ")
    }
    var audioInfo: String { [layer?.player.audioFormat, AudioSetup.routeDescription].compactMap { $0 }.joined(separator: " → ") }
    var engineName: String { layer.map { String(describing: type(of: $0.player)) } ?? "" }
}

extension PlayerController: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) { stateChanged(state) }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) { timeChanged(currentTime, totalTime) }
    func player(layer: KSPlayerLayer, finish error: Error?) { finished(error) }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
