import Foundation

/// Playback decisions for Apple TV 4K.
///
/// What the hardware and tvOS allow (and how this app uses it, the way Infuse does):
///  - The app plays the original file with its own FFmpeg-based player (KSPlayer). MKV, MP4, TS, AVI… open as they are;
///    the server never converts anything.
///  - Video: HEVC/H.264/AV1 (A15+)/VP9 in hardware. HDR10, HLG and HDR10+ go out as they are when the Apple TV is set to
///    "Match Dynamic Range". Dolby Vision profile 8 plays its HDR10 base layer; profile 5 is converted to HDR10 by the
///    player (KSPlayer's free build does not send Dolby Vision RPU metadata to the TV).
///  - Audio: every codec is decoded in the app (TrueHD, DTS, DTS-HD MA, E-AC3, AC3, AAC, FLAC…) to multichannel PCM, up
///    to 7.1. Over HDMI that is lossless multichannel PCM. On AirPods/Beats, tvOS turns 5.1/7.1 PCM into Spatial Audio
///    with head tracking, for every surround track, not only Dolby Atmos. Atmos height objects are not kept on that path
///    (they are folded into the 7.1 bed), the same as in Infuse.
///  - The one path that keeps Dolby Atmos objects is Apple's own decoder (AVPlayer) with Dolby Digital Plus (E-AC3 JOC).
///    AVPlayer can't open MKV, so the app uses it for MP4/MOV files with DD+ Atmos, and optionally for MKV through a
///    server remux (video and audio copied, only the container changes).
enum Decide {
    enum Engine: String {
        case ffmpeg      // KSMEPlayer: the original file, decoded in the app
        case apple       // AVPlayer: the original file (MP4/MOV only)
        case appleRemux  // AVPlayer: server repackages the file as HLS, nothing re-encoded
    }

    struct Plan {
        var media: PlexMedia?
        var mediaIndex: Int
        var part: PlexPart?
        var video: PlexStream?
        var audio: PlexStream?
        var subtitle: PlexStream?
        var engine: Engine
        var note: String
        var warnings: [String]
        var hdr: String { Decide.hdrLabel(video) }
    }

    // Plex mixes ISO 639-2 bibliographic and terminology codes; compare on one of them.
    private static let langAlias = ["deu": "ger", "fra": "fre", "zho": "chi", "nld": "dut", "ces": "cze", "ell": "gre", "fas": "per",
                                    "ron": "rum", "slk": "slo", "sqi": "alb", "hye": "arm", "eus": "baq", "mya": "bur", "kat": "geo",
                                    "isl": "ice", "mkd": "mac", "msa": "may", "cym": "wel"]
    private static let iso1 = ["en": "eng", "tr": "tur", "de": "ger", "fr": "fre", "es": "spa", "it": "ita", "ja": "jpn", "ko": "kor",
                               "zh": "chi", "ru": "rus", "pt": "por", "nl": "dut", "sv": "swe", "da": "dan", "no": "nor", "fi": "fin",
                               "pl": "pol", "ar": "ara", "el": "gre", "he": "heb", "hi": "hin", "cs": "cze", "hu": "hun", "ro": "rum"]
    static func norm(_ code: String?) -> String? {
        guard let c = code?.lowercased(), !c.isEmpty else { return nil }
        if let three = iso1[c] { return three }
        return langAlias[c] ?? c
    }
    static func sameLang(_ a: String?, _ b: String?) -> Bool {
        guard let a = norm(a), let b = norm(b) else { return false }
        return a == b
    }
    /// ISO 639-1 code for online services (OpenSubtitles wants "en", "tr").
    static func iso639_1(_ code: String?) -> String? {
        guard let n = norm(code) else { return nil }
        if n.count == 2 { return n }
        return iso1.first { $0.value == n }?.key
    }

    static func isAtmos(_ s: PlexStream?) -> Bool {
        guard let s else { return false }
        return "\(s.extendedDisplayTitle) \(s.displayTitle) \(s.title ?? "") \(s.profile ?? "")".lowercased().contains("atmos")
    }
    static func isTrueHD(_ s: PlexStream) -> Bool { s.codec.contains("truehd") || s.codec == "mlp" }
    static func isDTS(_ s: PlexStream) -> Bool { s.codec.hasPrefix("dca") || s.codec.hasPrefix("dts") }
    static func isLossless(_ s: PlexStream) -> Bool {
        isTrueHD(s) || ["flac", "pcm", "lpcm", "alac"].contains(s.codec) || (isDTS(s) && (s.profile ?? "").lowercased().contains("ma"))
    }
    static func isImageSub(_ s: PlexStream) -> Bool {
        ["pgs", "hdmv_pgs_subtitle", "vobsub", "dvd_subtitle", "dvb_subtitle"].contains(s.codec) || s.codec.contains("pgs")
    }

    static func hdrLabel(_ v: PlexStream?) -> String {
        guard let v else { return "SDR" }
        if v.doviPresent {
            let dv = "Dolby Vision P\(v.doviProfile.map(String.init) ?? "?")"
            // Many DV profile 8 files also carry HDR10+ metadata; that's what a Samsung TV shows.
            if isHDR10Plus(v) { return dv + " + HDR10+" }
            return dv + ((v.doviBLCompatID ?? 0) > 0 ? " (HDR10 base)" : "")
        }
        if isHDR10Plus(v) { return "HDR10+" }
        if v.colorTrc == "smpte2084" { return "HDR10" }
        if v.colorTrc == "arib-std-b67" { return "HLG" }
        return "SDR"
    }

    static func isHDR10Plus(_ v: PlexStream?) -> Bool {
        guard let v else { return false }
        return "\(v.extendedDisplayTitle) \(v.displayTitle) \(v.title ?? "")".uppercased().contains("HDR10+")
    }

    static func is8K(_ m: PlexMedia?) -> Bool {
        (m?.videoResolution ?? "").lowercased() == "8k" || (m?.width ?? 0) >= 7000
    }

    static func audioLabel(_ s: PlexStream?) -> String { s?.extendedDisplayTitle ?? "None" }

    /// Ranks tracks of one language: lossless first, then Atmos, then channel count.
    private static func quality(_ s: PlexStream) -> Int {
        (isLossless(s) ? 1000 : 0) + (isAtmos(s) ? 100 : 0) + s.channels
    }

    @MainActor
    static func chooseAudio(_ part: PlexPart?, requested: Int?, settings: AppSettings) -> PlexStream? {
        let audios = part?.audioStreams ?? []
        if let requested, let s = audios.first(where: { $0.id == requested }) { return s }
        let lang = settings.audioLanguage.isEmpty ? nil : settings.audioLanguage
        var base = lang.map { l in audios.filter { sameLang($0.languageCode, l) } } ?? []
        if base.isEmpty, let first = audios.first(where: { $0.selected }) ?? audios.first {
            base = audios.filter { $0.languageCode == first.languageCode }
        }
        // Same language, no commentary tracks.
        let candidates = base.filter { !($0.title ?? "").lowercased().contains("comment") }
        switch settings.audioPreference {
        case .atmosObjects:
            if let atmos = candidates.first(where: { isAtmos($0) && $0.codec == "eac3" }) { return atmos }
            return candidates.max { quality($0) < quality($1) } ?? audios.first
        case .best:
            return candidates.max { quality($0) < quality($1) } ?? audios.first
        case .serverDefault:
            return audios.first(where: { $0.selected }) ?? audios.first
        }
    }

    /// Default subtitle, from the subtitle mode ("off" | "forced" | "always") and language.
    /// Image subtitles (PGS/VobSub) are fine here: the player draws them itself.
    @MainActor
    static func chooseSubtitle(_ part: PlexPart?, audio: PlexStream?, settings: AppSettings) -> PlexStream? {
        let subs = part?.subtitleStreams ?? []
        guard !subs.isEmpty else { return nil }
        let lang = settings.subtitleLanguage.isEmpty ? audio?.languageCode : settings.subtitleLanguage
        let inLang: (PlexStream) -> Bool = { lang == nil || sameLang($0.languageCode, lang) }
        switch settings.subtitleMode {
        case .off: return nil
        case .forced:
            return subs.first { $0.forced && (sameLang($0.languageCode, audio?.languageCode) || inLang($0)) }
        case .always:
            // Don't show full subtitles in the language you're already listening to, unless asked for.
            if let audio, sameLang(audio.languageCode, lang), !settings.subtitlesInAudioLanguage {
                return subs.first { $0.forced && sameLang($0.languageCode, audio.languageCode) }
            }
            return subs.first { inLang($0) && !$0.forced && !$0.hearingImpaired }
                ?? subs.first { inLang($0) && !$0.forced }
                ?? subs.first(where: inLang)
        }
    }

    @MainActor
    static func plan(_ item: PlexItem, mediaIndex: Int = 0, audioId: Int? = nil, subtitleId: Int?? = nil, settings: AppSettings) -> Plan {
        let media = item.media.indices.contains(mediaIndex) ? item.media[mediaIndex] : item.media.first
        let part = media?.part
        let video = part?.videoStream
        let audio = chooseAudio(part, requested: audioId, settings: settings)
        let subtitle: PlexStream?
        if let pick = subtitleId { subtitle = pick.flatMap { id in part?.subtitleStreams.first { $0.id == id } } } else {
            subtitle = chooseSubtitle(part, audio: audio, settings: settings)
        }
        var warnings: [String] = []
        let container = (media?.container ?? part?.container ?? "").lowercased()

        var engine = Engine.ffmpeg
        var note: String
        if let audio {
            let channels = audio.channels >= 8 ? "7.1" : audio.channels >= 6 ? "5.1" : audio.channels == 2 ? "stereo" : "\(audio.channels) ch"
            note = "Original file, decoded on the Apple TV. \(audioLabel(audio)) plays as \(channels) PCM"
            note += audio.channels > 2 ? " (Spatial Audio on AirPods)." : "."
            if isAtmos(audio) && audio.codec == "eac3" {
                if ["mp4", "m4v", "mov"].contains(container) && settings.appleDecoderForAtmos {
                    engine = .apple
                    note = "Dolby Atmos (DD+) through Apple's decoder: Atmos to the soundbar, Spatial Audio with height on AirPods."
                } else if settings.remuxForAtmos {
                    engine = .appleRemux
                    note = "Dolby Atmos (DD+): the server repackages the MKV as HLS (nothing re-encoded) so Apple's decoder sends Dolby Atmos instead of PCM."
                } else {
                    note += " Atmos height objects are folded into the 7.1 mix."
                }
            } else if isAtmos(audio) {
                note += " Atmos height objects are folded into the 7.1 mix."
            }
        } else {
            note = "Original file, decoded on the Apple TV."
        }
        if is8K(media) {
            warnings.append("Apple TV outputs at most 4K, so this 8K file is scaled to 4K. Use the TV's own Plex HDR app for 8K.")
        }
        if let video, video.doviPresent, video.doviProfile == 5 {
            warnings.append("Dolby Vision profile 5 has no HDR10 layer; the player converts it to HDR10.")
        }
        if engine != .ffmpeg, let s = subtitle, isImageSub(s) {
            // AVPlayer can't draw PGS from an MKV remux; keep the app's player so the subtitle shows.
            engine = .ffmpeg
            warnings.append("Image subtitles need the app's player, so Atmos objects are folded into 7.1 for this title.")
        }
        return Plan(media: media, mediaIndex: mediaIndex, part: part, video: video, audio: audio, subtitle: subtitle,
                    engine: engine, note: note, warnings: warnings)
    }

    /// Apple TV-style badges for the details page.
    static func badges(_ plan: Plan) -> [String] {
        var out: [String] = []
        let m = plan.media
        if is8K(m) { out.append("8K") }
        else if m?.videoResolution?.lowercased() == "4k" || (m?.width ?? 0) >= 3800 { out.append("4K") }
        else if let r = m?.videoResolution, r.contains("1080") || r.contains("720") { out.append("HD") }
        if let v = plan.video {
            let h = hdrLabel(v)
            if isHDR10Plus(v) { out.append("HDR10+") }
            if v.doviPresent { out.append("Dolby Vision") }
            else if !isHDR10Plus(v) && h != "SDR" { out.append(h) }
        }
        if let a = plan.audio {
            if isAtmos(a) { out.append("Dolby Atmos") }
            else if a.channels >= 8 { out.append("7.1") }
            else if a.channels >= 6 { out.append("5.1") }
            if a.channels > 2 || isAtmos(a) { out.append("Spatial Audio") }
        }
        let subs = plan.part?.subtitleStreams ?? []
        if subs.contains(where: { $0.hearingImpaired }) { out.append("SDH") } else if !subs.isEmpty { out.append("CC") }
        return out
    }
}
