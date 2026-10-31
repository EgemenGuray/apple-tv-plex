import AVFoundation
#if KSPLAYER
import KSPlayer
#endif
import SwiftUI

@main
struct PlexHDRApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        AudioSetup.configure()
        #if KSPLAYER
        // The app's own FFmpeg player for everything (like Infuse). It decodes every audio codec to multichannel PCM,
        // which tvOS spatializes on AirPods. AVPlayer is only used when Decide picks it for Dolby Atmos (DD+).
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        // AVSampleBufferAudioRenderer: multichannel output with Spatial Audio, synced by the system clock.
        KSOptions.audioPlayerType = AudioRendererPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true
        KSOptions.isAccurateSeek = true
        KSOptions.canBackgroundPlay = false
        KSOptions.logLevel = .warning
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(PlexClient.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(PlayerPresenter.shared)
                .preferredColorScheme(.dark)
                #if os(macOS)
                .frame(minWidth: 1000, minHeight: 640)
                #endif
        }
        .onChange(of: phase) { _, p in
            if p != .active { TitleMemory.shared.flush() }
        }
    }
}

enum AudioSetup {
    /// Movie playback mode with multichannel content allowed: tvOS then renders 5.1/7.1 (and Dolby Atmos from Apple's
    /// decoder) as Spatial Audio on AirPods and Beats, with head tracking when the user has it on.
    static func configure() {
        #if !os(macOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setSupportsMultichannelContent(true)
        try? s.setActive(true)
        matchOutputChannels()
        #endif
    }

    /// Ask for as many output channels as the route has (8 over HDMI to a 7.1 receiver, and the spatial renderer's
    /// multichannel input for AirPods). Called again when the route changes.
    static func matchOutputChannels() {
        #if !os(macOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredOutputNumberOfChannels(max(2, s.maximumOutputNumberOfChannels))
        #endif
    }

    static var routeDescription: String {
        #if os(macOS)
        // macOS renders multichannel to the selected output and spatializes it on AirPods by itself.
        return "System output"
        #else
        let s = AVAudioSession.sharedInstance()
        let port = s.currentRoute.outputs.first
        var text = "\(port?.portName ?? "Unknown") · \(s.outputNumberOfChannels) ch"
        if port?.isSpatialAudioEnabled == true { text += " · Spatial Audio" }
        return text
        #endif
    }
}

/// Global "play this" request; the root view presents the player full screen.
@MainActor
final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()
    struct Request: Identifiable {
        let id = UUID()
        var item: PlexItem
        var startAt: TimeInterval?     // nil = resume point
        var mediaIndex: Int?
        var audioId: Int?
        var subtitleId: Int??
    }
    @Published var request: Request?
    /// Bumped after playback so screens reload progress and watched state.
    @Published var playbackEnded = 0

    /// Closes the player. (On the Mac the player is an overlay, not a cover, so it reports the end itself.)
    func close() {
        request = nil
        #if os(macOS)
        playbackEnded += 1
        #endif
    }

    func play(_ item: PlexItem, from start: TimeInterval? = nil, mediaIndex: Int? = nil, audioId: Int? = nil, subtitleId: Int?? = nil) {
        request = Request(item: item, startAt: start, mediaIndex: mediaIndex, audioId: audioId, subtitleId: subtitleId)
    }
}

enum Route: Hashable {
    case item(PlexItem)
    case person(PlexPerson)
    case collection(PlexItem)
}
