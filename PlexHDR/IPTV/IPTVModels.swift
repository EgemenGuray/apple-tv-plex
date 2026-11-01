import Foundation
import SwiftUI

// IPTV: M3U playlists and Xtream Codes accounts, with an XMLTV guide, catch-up, films and series.
// Everything here is plain data; IPTVStore loads, caches and combines it.

/// A source the user added: an M3U/M3U8 address or an Xtream Codes login.
struct IPTVPlaylist: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case m3u, xtream
        var id: String { rawValue }
        var label: String { self == .m3u ? "M3U playlist" : "Xtream Codes" }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// M3U: the playlist address. Xtream: the server address (http://host:port).
    var url: String
    var username = ""
    var password = ""
    /// Extra guide addresses (comma separated). The playlist's own guide is used as well.
    var epgURL = ""
    var userAgent = ""
    /// Index into IPTVPalette: each source has a colour so search results show where they come from.
    var colorIndex = 0
    var enabled = true
    var lastRefresh: Date?

    var color: Color { IPTVPalette.color(colorIndex) }
}

enum IPTVPalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

/// How a channel's past programmes are requested (M3U `catchup=` attribute, or Xtream's timeshift API).
struct IPTVCatchup: Codable, Hashable {
    /// default, append, shift, flussonic, xc (Xtream).
    var mode: String
    var days: Int
    var source: String?
}

struct IPTVChannel: Codable, Identifiable, Hashable {
    /// "<playlist id>|<stream key>": stable across refreshes so favourites survive.
    var id: String
    var playlistID: UUID
    var name: String
    var number: Int?
    var logo: String?
    var group: String
    var url: String
    var epgID: String?
    var catchup: IPTVCatchup?
    var userAgent: String?
    /// Xtream stream id (for timeshift URLs).
    var streamID: Int?

    var hasCatchup: Bool { (catchup?.days ?? 0) > 0 }
}

struct IPTVMovie: Codable, Identifiable, Hashable {
    var id: String
    var playlistID: UUID
    var name: String
    var poster: String?
    var group: String
    var url: String
    var rating: Double?
    var year: Int?
    var added: Date?
    var streamID: Int?
    var plot: String?
}

struct IPTVSeries: Codable, Identifiable, Hashable {
    var id: String
    var playlistID: UUID
    var name: String
    var poster: String?
    var group: String
    var plot: String?
    var rating: Double?
    var year: Int?
    var genre: String?
    var seriesID: Int?
    /// M3U series carry their episodes; Xtream ones are fetched when opened.
    var episodes: [IPTVEpisode]?
}

struct IPTVEpisode: Codable, Identifiable, Hashable {
    var id: String
    var season: Int
    var number: Int
    var title: String
    var url: String
    var plot: String?
    var thumb: String?
    var duration: TimeInterval?

    var label: String { "S\(season) E\(number)" }
}

/// Extra details for a film or series (Xtream get_vod_info / get_series_info).
struct IPTVDetails: Hashable {
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var released: String?
    var duration: TimeInterval?
    var rating: Double?
    var backdrop: String?
    var poster: String?
    var trailer: String?
    var episodes: [IPTVEpisode] = []
}

/// One guide entry.
struct IPTVProgramme: Codable, Hashable, Identifiable {
    var channel: String
    var start: Date
    var end: Date
    var title: String
    var desc: String?
    var category: String?
    var icon: String?
    var episode: String?

    var id: String { "\(channel)|\(start.timeIntervalSince1970)" }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func isAiring(at d: Date = Date()) -> Bool { start <= d && d < end }
    func progress(at d: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, d.timeIntervalSince(start) / duration))
    }
    var timeRange: String { "\(IPTVFormat.time(start)) – \(IPTVFormat.time(end))" }
}

/// Everything one source provided at its last refresh. Cached on disk as JSON.
struct IPTVContent: Codable {
    var channels: [IPTVChannel] = []
    var movies: [IPTVMovie] = []
    var series: [IPTVSeries] = []
    /// Category names in the provider's order.
    var liveGroups: [String] = []
    var movieGroups: [String] = []
    var seriesGroups: [String] = []
    /// Guide addresses named by the playlist itself (url-tvg / Xtream xmltv.php).
    var epgURLs: [String] = []
    /// Xtream server time zone: timeshift URLs are written in server time.
    var serverTimeZone: String?
    var account: IPTVAccount?
}

/// Xtream account status, shown in the playlist list.
struct IPTVAccount: Codable, Hashable {
    var status: String?
    var expires: Date?
    var maxConnections: Int?
    var activeConnections: Int?
    var trial: Bool?
}

/// A group of channels, films or series in one source.
struct IPTVGroup: Identifiable, Hashable {
    enum Kind: String { case live, movie, series }
    let playlistID: UUID
    let kind: Kind
    let name: String
    var id: String { IPTVGroup.key(playlistID, kind, name) }
    static func key(_ p: UUID, _ k: Kind, _ n: String) -> String { "\(p.uuidString)|\(k.rawValue)|\(n)" }
}

/// A reminder for an upcoming programme.
struct IPTVReminder: Codable, Hashable, Identifiable {
    var channelID: String
    var channelName: String
    var title: String
    var start: Date
    var id: String { "\(channelID)|\(start.timeIntervalSince1970)" }
}

enum IPTVError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

enum IPTVFormat {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }
    static func day(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        return dayFormatter.string(from: d)
    }
    static func minutes(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// Loose JSON values from Xtream panels: numbers arrive as strings and strings as numbers.
enum Loose {
    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    static func bool(_ v: Any?) -> Bool {
        switch v {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }
    static func date(_ v: Any?) -> Date? {
        int(v).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }
    static func year(_ v: Any?) -> Int? {
        guard let s = string(v), s.count >= 4, let y = Int(s.prefix(4)), y > 1880 else { return nil }
        return y
    }
}

extension String {
    /// For matching channel names against guide names: lower case, letters and digits only, no quality tags.
    var iptvKey: String {
        var s = lowercased()
        for tag in [" hd", " fhd", " uhd", " 4k", " sd", " hevc", "(hd)", "[hd]"] { s = s.replacingOccurrences(of: tag, with: "") }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return String(out)
    }
}
