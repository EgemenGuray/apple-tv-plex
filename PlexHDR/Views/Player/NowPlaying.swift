import Foundation
import MediaPlayer
import SwiftUI

/// The system's Now Playing card and remote commands: the iPhone's Apple TV Remote, Control Center, the lock screen,
/// AirPods gestures, the Touch Bar and media keys on the Mac, and Siri ("What did he say?" skips back).
/// One player owns it at a time; the owner publishes what's playing and clears it when it closes.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    struct Handlers {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var toggle: @MainActor () -> Void
        /// Seconds, negative for back. nil when the stream can't seek (live TV).
        var skip: (@MainActor (TimeInterval) -> Void)?
        /// Absolute position. nil when the stream can't seek.
        var seek: (@MainActor (TimeInterval) -> Void)?
    }

    struct Info: Equatable {
        var title: String
        var subtitle: String?
        var duration: TimeInterval
        var elapsed: TimeInterval
        var rate: Float
        var isLive = false
    }

    private var owner: ObjectIdentifier?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkURL: URL?
    private var last: Info?

    /// Takes over the remote commands for a player.
    func activate(owner: AnyObject, handlers h: Handlers) {
        removeTargets()
        self.owner = ObjectIdentifier(owner)
        let cc = MPRemoteCommandCenter.shared()
        add(cc.playCommand) { _ in h.play(); return .success }
        add(cc.pauseCommand) { _ in h.pause(); return .success }
        add(cc.togglePlayPauseCommand) { _ in h.toggle(); return .success }
        let settings = AppSettings.shared
        if let skip = h.skip {
            cc.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForward)]
            cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBack)]
            add(cc.skipForwardCommand) { e in
                let s = (e as? MPSkipIntervalCommandEvent)?.interval ?? Double(AppSettings.shared.skipForward)
                skip(abs(s)); return .success
            }
            add(cc.skipBackwardCommand) { e in
                let s = (e as? MPSkipIntervalCommandEvent)?.interval ?? Double(AppSettings.shared.skipBack)
                skip(-abs(s)); return .success
            }
        } else {
            cc.skipForwardCommand.isEnabled = false
            cc.skipBackwardCommand.isEnabled = false
        }
        if let seek = h.seek {
            add(cc.changePlaybackPositionCommand) { e in
                guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                seek(e.positionTime); return .success
            }
        } else {
            cc.changePlaybackPositionCommand.isEnabled = false
        }
        // Not used: keep the system from showing buttons that do nothing.
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.changePlaybackRateCommand.isEnabled = false
    }

    /// Publishes the Now Playing info. The system extrapolates the elapsed time from the rate, so this only needs
    /// calling when something changes (play, pause, seek, a new item) and now and then to correct drift.
    func update(owner: AnyObject, _ info: Info) {
        guard self.owner == ObjectIdentifier(owner) else { return }
        last = info
        publish()
    }

    /// Loads the artwork for the current item (once per URL).
    func setArtwork(owner: AnyObject, url: URL?) {
        guard self.owner == ObjectIdentifier(owner), url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        publish()
        guard let url else { return }
        Task { [weak self] in
            guard let img = await ImageCache.shared.load(url), let self, self.artworkURL == url else { return }
            self.artwork = Self.makeArtwork(img)
            self.publish()
        }
    }

    /// Clears the card and releases the commands, if this player still owns them.
    func clear(owner: AnyObject) {
        guard self.owner == ObjectIdentifier(owner) else { return }
        removeTargets()
        self.owner = nil
        last = nil
        artwork = nil
        artworkURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func publish() {
        guard let i = last else { return }
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: i.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, i.elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: Double(i.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: i.isLive,
        ]
        if let s = i.subtitle, !s.isEmpty { d[MPMediaItemPropertyArtist] = s }
        if i.duration > 0, !i.isLive { d[MPMediaItemPropertyPlaybackDuration] = i.duration }
        if let artwork { d[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = d
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = i.rate > 0 ? .playing : .paused
        #endif
    }

    /// Built outside the main actor: the system calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func add(_ cmd: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        cmd.isEnabled = true
        let token = cmd.addTarget { event in
            if Thread.isMainThread { return MainActor.assumeIsolated { action(event) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = action(event) } }
            return .success
        }
        targets.append((cmd, token))
    }

    private func removeTargets() {
        for (cmd, token) in targets { cmd.removeTarget(token) }
        targets = []
    }
}
