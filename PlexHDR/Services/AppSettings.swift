import Foundation
import SwiftUI

/// User settings, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum SubtitleMode: String, CaseIterable, Identifiable { case off, forced, always
        var id: String { rawValue }
        var label: String { ["off": "Off", "forced": "Forced only", "always": "Always"][rawValue]! }
    }
    enum AudioPreference: String, CaseIterable, Identifiable { case best, atmosObjects, serverDefault
        var id: String { rawValue }
        var label: String {
            switch self {
            case .best: return "Best track (lossless first)"
            case .atmosObjects: return "Prefer Dolby Atmos (DD+)"
            case .serverDefault: return "Plex's selected track"
            }
        }
    }
    enum SubtitleColor: String, CaseIterable, Identifiable { case white, yellow, cyan, green
        var id: String { rawValue }
        var color: UIColor { ["white": .white, "yellow": .systemYellow, "cyan": .cyan, "green": .systemGreen][rawValue]! }
    }
    enum SubtitleStyle: String, CaseIterable, Identifiable { case outline, shadow, box
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private let d = UserDefaults.standard

    @Published var audioLanguage: String { didSet { d.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var audioPreference: AudioPreference { didSet { d.set(audioPreference.rawValue, forKey: "audioPreference") } }
    @Published var appleDecoderForAtmos: Bool { didSet { d.set(appleDecoderForAtmos, forKey: "appleDecoderForAtmos") } }
    @Published var remuxForAtmos: Bool { didSet { d.set(remuxForAtmos, forKey: "remuxForAtmos") } }
    @Published var subtitleMode: SubtitleMode { didSet { d.set(subtitleMode.rawValue, forKey: "subtitleMode") } }
    @Published var subtitleLanguage: String { didSet { d.set(subtitleLanguage, forKey: "subtitleLanguage") } }
    @Published var subtitlesInAudioLanguage: Bool { didSet { d.set(subtitlesInAudioLanguage, forKey: "subtitlesInAudioLanguage") } }
    @Published var subtitleSize: Double { didSet { d.set(subtitleSize, forKey: "subtitleSize") } }
    @Published var subtitleColor: SubtitleColor { didSet { d.set(subtitleColor.rawValue, forKey: "subtitleColor") } }
    @Published var subtitleStyle: SubtitleStyle { didSet { d.set(subtitleStyle.rawValue, forKey: "subtitleStyle") } }
    @Published var subtitleBottomMargin: Double { didSet { d.set(subtitleBottomMargin, forKey: "subtitleBottomMargin") } }
    @Published var autoplayNext: Bool { didSet { d.set(autoplayNext, forKey: "autoplayNext") } }
    @Published var autoSkipIntro: Bool { didSet { d.set(autoSkipIntro, forKey: "autoSkipIntro") } }
    @Published var autoSkipCredits: Bool { didSet { d.set(autoSkipCredits, forKey: "autoSkipCredits") } }
    @Published var skipBack: Int { didSet { d.set(skipBack, forKey: "skipBack") } }
    @Published var skipForward: Int { didSet { d.set(skipForward, forKey: "skipForward") } }
    @Published var matchFrameRate: Bool { didSet { d.set(matchFrameRate, forKey: "matchFrameRate") } }
    @Published var tmdbArtwork: Bool { didSet { d.set(tmdbArtwork, forKey: "tmdbArtwork") } }
    @Published var showRatings: Bool { didSet { d.set(showRatings, forKey: "showRatings") } }

    // Online services keys (free accounts). Keys.swift (git-ignored) can supply defaults at build time.
    @Published var tmdbKey: String { didSet { d.set(tmdbKey, forKey: "tmdbKey") } }
    @Published var omdbKey: String { didSet { d.set(omdbKey, forKey: "omdbKey") } }
    @Published var openSubtitlesKey: String { didSet { d.set(openSubtitlesKey, forKey: "openSubtitlesKey") } }
    @Published var openSubtitlesUser: String { didSet { d.set(openSubtitlesUser, forKey: "openSubtitlesUser") } }
    @Published var openSubtitlesPassword: String { didSet { d.set(openSubtitlesPassword, forKey: "openSubtitlesPassword") } }

    private init() {
        // Reads go through a local reference: nested functions can't touch `self` before every property is set.
        let ud = UserDefaults.standard
        func s(_ k: String, _ def: String) -> String { ud.string(forKey: k) ?? def }
        func b(_ k: String, _ def: Bool) -> Bool { ud.object(forKey: k) == nil ? def : ud.bool(forKey: k) }
        func n(_ k: String, _ def: Double) -> Double { ud.object(forKey: k) == nil ? def : ud.double(forKey: k) }
        audioLanguage = s("audioLanguage", "")
        audioPreference = AudioPreference(rawValue: s("audioPreference", "")) ?? .best
        appleDecoderForAtmos = b("appleDecoderForAtmos", true)
        remuxForAtmos = b("remuxForAtmos", false)
        subtitleMode = SubtitleMode(rawValue: s("subtitleMode", "")) ?? .forced
        subtitleLanguage = s("subtitleLanguage", "")
        subtitlesInAudioLanguage = b("subtitlesInAudioLanguage", false)
        subtitleSize = n("subtitleSize", 1.0)
        subtitleColor = SubtitleColor(rawValue: s("subtitleColor", "")) ?? .white
        subtitleStyle = SubtitleStyle(rawValue: s("subtitleStyle", "")) ?? .outline
        subtitleBottomMargin = n("subtitleBottomMargin", 0.06)
        autoplayNext = b("autoplayNext", true)
        autoSkipIntro = b("autoSkipIntro", false)
        autoSkipCredits = b("autoSkipCredits", false)
        skipBack = Int(n("skipBack", 10))
        skipForward = Int(n("skipForward", 30))
        matchFrameRate = b("matchFrameRate", true)
        tmdbArtwork = b("tmdbArtwork", true)
        showRatings = b("showRatings", true)
        tmdbKey = s("tmdbKey", BuildKeys.tmdb)
        omdbKey = s("omdbKey", BuildKeys.omdb)
        openSubtitlesKey = s("openSubtitlesKey", BuildKeys.openSubtitles)
        openSubtitlesUser = s("openSubtitlesUser", BuildKeys.openSubtitlesUser)
        openSubtitlesPassword = s("openSubtitlesPassword", BuildKeys.openSubtitlesPassword)
    }
}
