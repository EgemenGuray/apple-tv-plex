#if !KSPLAYER
// iPhone and iPad: the free KSPlayer build has no iOS device binary, so these types provide the part of KSPlayer's API
// that the player uses, on top of AVPlayer. Plex repackages files AVPlayer can't open (MKV) as HLS without
// re-encoding the video, and converts audio codecs AVPlayer can't decode (TrueHD, DTS) to Dolby Digital Plus.
// Dolby Atmos, Dolby Vision, HDR10 and Spatial Audio on AirPods all come from Apple's own pipeline here.
import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

enum KSPlayerState {
    case initialized, preparing, readyToPlay, buffering, bufferFinished, paused, playedToTheEnd, error
    var isPlaying: Bool { self == .buffering || self == .bufferFinished }
}

protocol MediaPlayerTrack: AnyObject {
    var trackID: Int32 { get }
    var isEnabled: Bool { get }
    var name: String { get }
}

protocol SubtitleInfo: AnyObject {
    var subtitleID: String { get }
    var name: String { get }
}

final class URLSubtitleInfo: SubtitleInfo {
    let subtitleID: String
    let name: String
    let url: URL
    let languageCode: String?
    init(subtitleID: String, name: String, url: URL, languageCode: String?) {
        self.subtitleID = subtitleID; self.name = name; self.url = url; self.languageCode = languageCode
    }
}

/// Marker types: the player only has one engine here.
final class KSMEPlayer {}
final class KSAVPlayer {}

class KSOptions {
    var startPlayTime: TimeInterval = 0
    var autoSelectEmbedSubtitle = true
    var isAccurateSeek = true
    var registerRemoteControll = true
    var playerTypes: [Any.Type] = []
    /// Sent as the HTTP User-Agent (IPTV providers often require a specific one).
    var userAgent: String?
    var isLive: Bool?
    init() {}
    func wantedAudio(tracks: [any MediaPlayerTrack]) -> (any MediaPlayerTrack)? { nil }
    @MainActor func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {}
}

@MainActor
protocol KSPlayerLayerDelegate: AnyObject {
    func player(layer: KSPlayerLayer, state: KSPlayerState)
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval)
    func player(layer: KSPlayerLayer, finish error: Error?)
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval)
}

// MARK: - Subtitles

/// Text subtitles (SRT, WebVTT, ASS/SSA) drawn over the video.
@MainActor
final class SubtitleModel: ObservableObject {
    @Published var subtitleInfos: [any SubtitleInfo] = []
    var subtitleDelay: Double = 0
    fileprivate var cues: [SubtitleCue] = []
    fileprivate var selectedID: String?

    func addSubtitle(info: any SubtitleInfo) {
        if !subtitleInfos.contains(where: { $0.subtitleID == info.subtitleID }) { subtitleInfos.append(info) }
    }

    fileprivate func text(at t: TimeInterval) -> String? {
        let time = t - subtitleDelay
        // Cues are sorted by start; find the last one that started and check it hasn't ended.
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        // Overlapping cues: show every one that covers this moment.
        var lines: [String] = []
        var i = found
        while i >= 0, i >= found - 8 {
            if cues[i].start <= time && time < cues[i].end { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

struct SubtitleCue {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum SubtitleParser {
    static func parse(_ data: Data) -> [SubtitleCue] {
        // Turkish files are often Windows-1254.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1254) ?? String(decoding: data, as: UTF8.self)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let cues = normalized.contains("[Events]") ? parseASS(normalized) : parseSRT(normalized)
        return cues.sorted { $0.start < $1.start }
    }

    /// SRT and WebVTT: blocks with a "start --> end" line followed by the text.
    private static func parseSRT(_ s: String) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for block in s.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
            let clean = strip(body)
            if !clean.isEmpty { out.append(SubtitleCue(start: a, end: b, text: clean)) }
        }
        return out
    }

    /// ASS/SSA: "Dialogue:" lines; the text is the tenth field.
    private static func parseASS(_ s: String) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for line in s.split(separator: "\n") where line.hasPrefix("Dialogue:") {
            let fields = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10, let a = time(fields[1]), let b = time(fields[2]) else { continue }
            let body = fields[9].replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            let clean = strip(body)
            if !clean.isEmpty { out.append(SubtitleCue(start: a, end: b, text: clean)) }
        }
        return out
    }

    /// "01:02:03,456", "01:02:03.45", "02:03.456" or "0:01:02.34".
    private static func time(_ raw: String) -> TimeInterval? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    /// Drops HTML-style tags and ASS override blocks.
    private static func strip(_ s: String) -> String {
        var out = ""
        var depthAngle = 0, depthBrace = 0
        for ch in s {
            switch ch {
            case "<": depthAngle += 1
            case ">": if depthAngle > 0 { depthAngle -= 1 } else { out.append(ch) }
            case "{": depthBrace += 1
            case "}": if depthBrace > 0 { depthBrace -= 1 } else { out.append(ch) }
            default: if depthAngle == 0 && depthBrace == 0 { out.append(ch) }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tracks

final class AVAudioOptionTrack: MediaPlayerTrack {
    let option: AVMediaSelectionOption
    let trackID: Int32
    var isEnabled: Bool
    var name: String { option.displayName }
    init(option: AVMediaSelectionOption, order: Int, selected: Bool) {
        self.option = option
        // Never equal to a Plex stream index, so tracks are matched by order.
        trackID = Int32(-1 - order)
        isEnabled = selected
    }
}

struct PlayerChapter {
    let title: String
    let start: TimeInterval
}

// MARK: - Player

/// AVPlayer with the properties the info panel shows.
@MainActor
final class AVPlayerEngine {
    let avPlayer = AVPlayer()
    let view = AVPlayerHostView()
    fileprivate var audioGroup: AVMediaSelectionGroup?

    var contentMode: UIView.ContentMode = .scaleAspectFit {
        didSet {
            view.playerLayer.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : contentMode == .scaleToFill ? .resize : .resizeAspect
        }
    }

    var duration: TimeInterval {
        let d = avPlayer.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    var playbackRate: Float = 1 {
        didSet { avPlayer.defaultRate = playbackRate; if avPlayer.rate != 0 { avPlayer.rate = playbackRate } }
    }

    var chapters: [PlayerChapter] { [] }

    var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    func tracks(mediaType: AVMediaType) -> [any MediaPlayerTrack] {
        guard mediaType == .audio, let group = audioGroup, let item = avPlayer.currentItem else { return [] }
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { AVAudioOptionTrack(option: $1, order: $0, selected: $1 == current) }
    }

    func select(track: any MediaPlayerTrack) {
        guard let t = track as? AVAudioOptionTrack, let group = audioGroup else { return }
        avPlayer.currentItem?.select(t.option, in: group)
    }

    private var videoTrack: AVAssetTrack? {
        avPlayer.currentItem?.tracks.first { $0.assetTrack?.mediaType == .video }?.assetTrack
    }

    var naturalSize: CGSize { avPlayer.currentItem?.presentationSize ?? .zero }

    var videoFormat: String? {
        guard let desc = videoTrack?.formatDescriptions.first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
        return fourCC(code)
    }

    var dynamicRange: String? {
        guard let t = videoTrack else { return nil }
        if t.hasMediaCharacteristic(.containsHDRVideo) { return "HDR" }
        return "SDR"
    }

    var nominalFrameRate: Float { videoTrack?.nominalFrameRate ?? 0 }

    var audioFormat: String? {
        guard let group = audioGroup, let o = avPlayer.currentItem?.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return o.displayName
    }

    private func fourCC(_ c: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((c >> $0) & 0xFF))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

/// Video layer plus the subtitle label.
final class AVPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSubtitle()
    }

    func show(subtitle text: String?) {
        guard let text else { subtitleLabel.attributedText = nil; subtitleLabel.isHidden = true; return }
        let s = AppSettings.shared
        let size = max(14, bounds.height * 0.05) * CGFloat(s.subtitleSize)
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: s.subtitleColor.color]
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.layer.shadowOpacity = 0
        switch s.subtitleStyle {
        case .outline:
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -3.0
        case .shadow:
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = CGSize(width: 1, height: 1)
            attrs[.shadow] = shadow
        case .box:
            attrs[.backgroundColor] = UIColor.black.withAlphaComponent(0.6)
        }
        subtitleLabel.attributedText = NSAttributedString(string: text, attributes: attrs)
        subtitleLabel.isHidden = false
        layoutSubtitle()
    }

    private func layoutSubtitle() {
        let maxWidth = bounds.width * 0.9
        let fit = subtitleLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let margin = bounds.height * CGFloat(AppSettings.shared.subtitleBottomMargin)
        subtitleLabel.frame = CGRect(x: (bounds.width - fit.width) / 2, y: bounds.height - margin - fit.height, width: fit.width, height: fit.height)
    }
}

// MARK: - Layer

@MainActor
final class KSPlayerLayer {
    weak var delegate: (any KSPlayerLayerDelegate)?
    let subtitleModel = SubtitleModel()
    let player = AVPlayerEngine()
    private var options: KSOptions
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notes: [NSObjectProtocol] = []
    private var pip: AVPictureInPictureController?
    private var reportedReady = false
    private var userPaused = false

    init(url: URL, options: KSOptions, delegate: (any KSPlayerLayerDelegate)?) {
        self.options = options
        self.delegate = delegate
        player.view.playerLayer.player = player.avPlayer
        player.avPlayer.allowsExternalPlayback = true
        player.avPlayer.appliesMediaSelectionCriteriaAutomatically = false
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: player.view.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        statusObserver = player.avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            DispatchQueue.main.async { self?.statusChanged(status) }
        }
        // Let the system pick the first open, then the delegate's callbacks drive the rest.
        DispatchQueue.main.async { [weak self] in self?.set(url: url, options: options) }
    }

    func set(url: URL, options: KSOptions) {
        self.options = options
        reportedReady = false
        userPaused = false
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
        player.audioGroup = nil
        delegate?.player(layer: self, state: .preparing)

        let item: AVPlayerItem
        if let ua = options.userAgent, !ua.isEmpty {
            item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]]))
        } else {
            item = AVPlayerItem(url: url)
        }
        // Plex streams are long; let AVPlayer buffer ahead generously. Live TV starts sooner with less.
        item.preferredForwardBufferDuration = options.isLive == true ? 4 : 30
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            let err = it.error
            DispatchQueue.main.async { self?.itemStatusChanged(status, error: err) }
        }
        notes.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(layer: self, state: .playedToTheEnd)
                self.delegate?.player(layer: self, finish: nil)
            }
        })
        notes.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] n in
            let err = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(layer: self, finish: err ?? PlexError.message("Playback stopped."))
            }
        })
        player.avPlayer.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            guard !reportedReady, let item = player.avPlayer.currentItem else { return }
            reportedReady = true
            Task {
                player.audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
                if let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                    // The app draws its own subtitles.
                    item.select(nil, in: legible)
                }
                let start = options.startPlayTime
                if start > 0 {
                    let tolerance = options.isAccurateSeek ? CMTime.zero : CMTime(seconds: 2, preferredTimescale: 600)
                    _ = await player.avPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
                }
                delegate?.player(layer: self, state: .readyToPlay)
                play()
            }
        case .failed:
            delegate?.player(layer: self, state: .error)
            delegate?.player(layer: self, finish: error ?? PlexError.message("The video couldn't be opened."))
        default:
            break
        }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard reportedReady else { return }
        switch status {
        case .playing: delegate?.player(layer: self, state: .bufferFinished)
        case .waitingToPlayAtSpecifiedRate: delegate?.player(layer: self, state: .buffering)
        case .paused: delegate?.player(layer: self, state: .paused)
        @unknown default: break
        }
    }

    private func tick(_ t: TimeInterval) {
        guard t.isFinite else { return }
        player.view.show(subtitle: subtitleModel.selectedID == nil ? nil : subtitleModel.text(at: t))
        guard reportedReady else { return }
        delegate?.player(layer: self, currentTime: t, totalTime: player.duration)
    }

    func play() {
        userPaused = false
        player.avPlayer.playImmediately(atRate: player.playbackRate)
    }

    func pause() {
        userPaused = true
        player.avPlayer.pause()
    }

    func seek(time: TimeInterval, autoPlay: Bool) {
        let tolerance = options.isAccurateSeek ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
        player.avPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async { if autoPlay, self?.userPaused == false { self?.play() } }
        }
    }

    func stop() {
        player.avPlayer.pause()
        player.avPlayer.replaceCurrentItem(with: nil)
        if let timeObserver { player.avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver = nil
        itemObserver = nil
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
    }

    /// Loads a subtitle file (or turns subtitles off with nil).
    func select(subtitleInfo: (any SubtitleInfo)?) {
        guard let info = subtitleInfo as? URLSubtitleInfo else {
            subtitleModel.selectedID = nil
            subtitleModel.cues = []
            player.view.show(subtitle: nil)
            return
        }
        subtitleModel.addSubtitle(info: info)
        subtitleModel.selectedID = info.subtitleID
        Task {
            let data: Data?
            if info.url.isFileURL { data = try? Data(contentsOf: info.url) }
            else { data = try? await URLSession.shared.data(from: info.url).0 }
            guard subtitleModel.selectedID == info.subtitleID else { return }
            subtitleModel.cues = data.map(SubtitleParser.parse) ?? []
        }
    }

    func makeUIView() -> UIView { player.view }
    func updateUIView(_ view: UIView) {}
}
#endif
