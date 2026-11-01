import Foundation

/// Picture and sound quality of a channel: read from tags in its name and group ("UK: BBC One FHD", "4K | Sports",
/// "HEVC", "5.1") and corrected by what the player actually measured the last time it played.
enum IPTVTag: String, CaseIterable, Identifiable, Codable, Hashable {
    case uhd = "4K"
    case fhd = "FHD"
    case hd = "HD"
    case sd = "SD"
    case hdr = "HDR"
    case surround = "5.1"
    case stereo = "Stereo"
    case hevc = "HEVC"

    var id: String { rawValue }
    var isVideo: Bool { [.uhd, .fhd, .hd, .sd].contains(self) }

    /// Tags found in a channel's name or group.
    static func parse(_ text: String) -> Set<IPTVTag> {
        let up = " " + text.uppercased()
            .replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ").replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") + " "
        func has(_ words: [String]) -> Bool { words.contains { up.contains(" \($0) ") } }
        var t = Set<IPTVTag>()
        if has(["4K", "UHD", "2160P", "2160", "8K"]) { t.insert(.uhd) }
        else if has(["FHD", "1080P", "1080", "1080I", "FULLHD", "FULL HD"]) { t.insert(.fhd) }
        else if has(["HD", "720P", "720", "HD+"]) { t.insert(.hd) }
        else if has(["SD", "576P", "480P", "LQ"]) { t.insert(.sd) }
        if has(["HDR", "HDR10", "HLG", "DV", "DOLBY VISION"]) { t.insert(.hdr) }
        if has(["5.1", "7.1", "DD5.1", "DD+", "AC3", "EAC3", "E AC3", "ATMOS", "DOLBY", "SURROUND"]) { t.insert(.surround) }
        if has(["STEREO", "2.0"]) { t.insert(.stereo) }
        if has(["HEVC", "H265", "H.265", "X265"]) { t.insert(.hevc) }
        return t
    }
}

/// What the player saw when the channel last played.
struct IPTVMeasured: Codable, Hashable {
    var height: Int
    var channels: Int?
    var hdr: Bool

    var tags: Set<IPTVTag> {
        var t = Set<IPTVTag>()
        switch height {
        case 1700...: t.insert(.uhd)
        case 1000..<1700: t.insert(.fhd)
        case 700..<1000: t.insert(.hd)
        case 1..<700: t.insert(.sd)
        default: break
        }
        if hdr { t.insert(.hdr) }
        if let c = channels { t.insert(c > 2 ? .surround : .stereo) }
        return t
    }

    /// Channel count from the player's description of the audio ("5.1", "6 channels", "stereo"…).
    static func channels(from text: String) -> Int? {
        let s = text.lowercased()
        if s.contains("7.1") || s.contains("8 ch") || s.contains("8ch") { return 8 }
        if s.contains("5.1") || s.contains("6 ch") || s.contains("6ch") || s.contains("atmos") { return 6 }
        if s.contains("stereo") || s.contains("2 ch") || s.contains("2ch") || s.contains("2.0") { return 2 }
        if s.contains("mono") || s.contains("1 ch") { return 1 }
        return nil
    }
}
