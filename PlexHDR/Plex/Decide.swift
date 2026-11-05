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

    // MARK: - Track labels for the player's Audio & Subtitles panel

    /// "English", from the stream's language name or code.
    static func languageName(_ s: PlexStream) -> String {
        if let l = s.language, !l.isEmpty { return l }
        if let code = s.languageCode, let name = Locale(identifier: "en").localizedString(forLanguageCode: iso639_1(code) ?? code) { return name }
        return "Unknown"
    }

    /// "TrueHD Atmos", "DTS-HD MA", "Dolby Digital+", "AAC".
    static func audioFormatName(_ s: PlexStream) -> String {
        let profile = (s.profile ?? "").lowercased()
        var name: String
        switch s.codec {
        case "truehd", "mlp": name = "TrueHD"
        case "eac3": name = "Dolby Digital+"
        case "ac3": name = "Dolby Digital"
        case "aac": name = "AAC"
        case "flac": name = "FLAC"
        case "alac": name = "ALAC"
        case "opus": name = "Opus"
        case "vorbis": name = "Vorbis"
        case "mp3": name = "MP3"
        case "mp2": name = "MP2"
        default:
            if isDTS(s) {
                name = profile.contains("x") ? "DTS:X" : profile.contains("ma") ? "DTS-HD MA" : profile.contains("hra") ? "DTS-HD HRA" : "DTS"
            } else if s.codec.hasPrefix("pcm") || s.codec == "lpcm" {
                name = "PCM"
            } else {
                name = s.codec.uppercased()
            }
        }
        if isAtmos(s) && name != "DTS:X" { name += " Atmos" }
        return name
    }

    static func channelLayoutName(_ channels: Int) -> String? {
        switch channels {
        case 0: return nil
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    static func isCommentary(_ s: PlexStream) -> Bool {
        "\(s.title ?? "") \(s.extendedDisplayTitle)".lowercased().contains("comment")
    }

    /// "English · TrueHD Atmos 7.1"
    static func audioTrackTitle(_ s: PlexStream) -> String {
        let format = [audioFormatName(s), channelLayoutName(s.channels)].compactMap { $0 }.joined(separator: " ")
        return "\(languageName(s)) · \(format)"
    }

    /// "Commentary", or the track's own title when it says something the language and format don't.
    static func audioTrackDetail(_ s: PlexStream) -> String? {
        if isCommentary(s) { return "Commentary" }
        return meaningfulTitle(s)
    }

    /// "English", "English · Forced", "English · SDH".
    static func subtitleTitle(_ s: PlexStream) -> String {
        var bits = [languageName(s)]
        if s.forced { bits.append("Forced") }
        if s.hearingImpaired { bits.append("SDH") }
        if isCommentary(s) { bits.append("Commentary") }
        return bits.joined(separator: " · ")
    }

    /// "SRT · External", "PGS", with the track's own title in front when it adds something ("Signs & Songs").
    static func subtitleDetail(_ s: PlexStream) -> String {
        let formats = ["srt": "SRT", "subrip": "SRT", "ass": "ASS", "ssa": "SSA", "pgs": "PGS", "hdmv_pgs_subtitle": "PGS",
                       "vobsub": "VobSub", "dvd_subtitle": "VobSub", "dvb_subtitle": "DVB", "webvtt": "WebVTT", "vtt": "WebVTT",
                       "mov_text": "Text", "tx3g": "Text", "eia_608": "CC", "eia_708": "CC", "smi": "SAMI"]
        var bits: [String] = []
        if let t = meaningfulTitle(s), !isCommentary(s) { bits.append(t) }
        bits.append(formats[s.codec] ?? s.codec.uppercased())
        if s.isExternal { bits.append("External") }
        return bits.joined(separator: " · ")
    }

    /// The stream's title unless it only repeats the language, the format or the flags.
    private static func meaningfulTitle(_ s: PlexStream) -> String? {
        guard let t = s.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let noise = [languageName(s).lowercased(), s.languageCode?.lowercased() ?? "", s.codec, "forced", "sdh", "cc", "full", "default",
                     "subtitles", "subtitle", "subs", "audio", "stereo", "mono", "surround", "5.1", "7.1", "2.0", "atmos", "truehd",
                     "dolby", "digital", "plus", "dts-hd", "dts", "ma", "hd", "aac", "ac3", "eac3", "dd+", "dd", "flac", "pcm", "srt",
                     "pgs", "ass", "lossless", "hearing", "impaired"]
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "-" && $0 != "." })
        let leftover = words.map(String.init).filter { !noise.contains($0) }.joined()
        return leftover.filter { $0.isLetter || $0.isNumber }.count >= 2 ? t : nil
    }

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
            note = "Original file, decoded on \(Platform.deviceNoun). \(audioLabel(audio)) plays as \(channels) PCM"
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
            note = "Original file, decoded on \(Platform.deviceNoun)."
        }
        if !Platform.hasFFmpeg {
            (engine, note) = appleOnlyPlan(container: container, video: video, audio: audio)
            if let s = subtitle, isImageSub(s) {
                warnings.append("Image subtitles (PGS/VobSub) can't be drawn on this device; pick a text subtitle or search online.")
            }
        }
        if is8K(media), Platform.isTV {
            warnings.append("Apple TV outputs at most 4K, so this 8K file is scaled to 4K. Use Lumen on the TV for 8K.")
        }
        if let video, video.doviPresent, video.doviProfile == 5 {
            warnings.append("Dolby Vision profile 5 has no HDR10 layer; the player converts it to HDR10.")
        }
        if Platform.hasFFmpeg, engine != .ffmpeg, let s = subtitle, isImageSub(s) {
            // AVPlayer can't draw PGS from an MKV remux; keep the app's player so the subtitle shows.
            engine = .ffmpeg
            warnings.append("Image subtitles need the app's player, so Atmos objects are folded into 7.1 for this title.")
        }
        return Plan(media: media, mediaIndex: mediaIndex, part: part, video: video, audio: audio, subtitle: subtitle,
                    engine: engine, note: note, warnings: warnings)
    }

    /// iPhone and iPad play everything through AVPlayer: MP4/MOV with codecs it decodes open directly; anything else
    /// is repackaged by the server as HLS (video copied, audio copied when it's Dolby Digital (Plus) or AAC, otherwise
    /// converted to Dolby Digital Plus).
    private static func appleOnlyPlan(container: String, video: PlexStream?, audio: PlexStream?) -> (Engine, String) {
        let appleVideo = ["hevc", "h265", "h264", "avc1", "hvc1", "dvhe", "dvh1"].contains(video?.codec.lowercased() ?? "h264")
        let appleAudio = ["aac", "ac3", "eac3", "alac", "mp3", "flac", "opus"].contains(audio?.codec.lowercased() ?? "aac")
        let atmos = audio.map { isAtmos($0) } == true && audio?.codec == "eac3"
        let spatial = (audio?.channels ?? 2) > 2 ? " Multichannel audio plays as Spatial Audio on AirPods." : ""
        if ["mp4", "m4v", "mov"].contains(container) && appleVideo && appleAudio {
            return (.apple, (atmos ? "Original file with Dolby Atmos through Apple's decoder." : "Original file, played by Apple's player.") + spatial)
        }
        let audioNote = appleAudio && audio?.codec.lowercased() != "flac" && audio?.codec.lowercased() != "opus"
            ? (atmos ? "Dolby Atmos is kept." : "audio is kept as is.")
            : "\(audio.map { audioLabel($0) } ?? "The audio") is converted to Dolby Digital Plus by the server."
        return (.appleRemux, "The server repackages the file as HLS for Apple's player (video not re-encoded); \(audioNote)\(spatial)")
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
