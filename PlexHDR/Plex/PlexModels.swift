import Foundation

typealias JSON = [String: Any]

/// Plex sends numbers as numbers or strings and flags as bools or 0/1 depending on the server version and field,
/// so the models wrap the raw dictionary and read it leniently instead of using strict Codable types.
protocol PlexObject {
    var raw: JSON { get }
}

extension PlexObject {
    func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func int(_ key: String) -> Int? {
        switch raw[key] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }
    func double(_ key: String) -> Double? {
        switch raw[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }
    func list(_ key: String) -> [JSON] { raw[key] as? [JSON] ?? [] }
    func tags(_ key: String) -> [String] { list(key).compactMap { $0["tag"] as? String } }
}

struct PlexItem: PlexObject, Identifiable, Hashable, @unchecked Sendable {
    let raw: JSON

    var id: String { ratingKey ?? key ?? UUID().uuidString }
    var ratingKey: String? { string("ratingKey") }
    var key: String? { string("key") }
    var type: String { string("type") ?? "" }
    var title: String { string("title") ?? "" }
    var titleSort: String? { string("titleSort") }
    var originalTitle: String? { string("originalTitle") }
    var summary: String? { string("summary") }
    var tagline: String? { string("tagline") }
    var year: Int? { int("year") }
    var index: Int? { int("index") }
    var parentIndex: Int? { int("parentIndex") }
    var parentTitle: String? { string("parentTitle") }
    var grandparentTitle: String? { string("grandparentTitle") }
    var parentRatingKey: String? { string("parentRatingKey") }
    var grandparentRatingKey: String? { string("grandparentRatingKey") }
    var contentRating: String? { string("contentRating") }
    var studio: String? { string("studio") }
    var durationMs: Int? { int("duration") }
    var viewOffsetMs: Int { int("viewOffset") ?? 0 }
    var viewCount: Int { int("viewCount") ?? 0 }
    var lastViewedAt: Int? { int("lastViewedAt") }
    var addedAt: Int? { int("addedAt") }
    var leafCount: Int? { int("leafCount") }
    var viewedLeafCount: Int? { int("viewedLeafCount") }
    var childCount: Int? { int("childCount") }
    var originallyAvailableAt: String? { string("originallyAvailableAt") }
    var thumb: String? { string("thumb") }
    var art: String? { string("art") }
    var parentThumb: String? { string("parentThumb") }
    var grandparentThumb: String? { string("grandparentThumb") }
    var grandparentArt: String? { string("grandparentArt") }
    var rating: Double? { double("rating") }
    var audienceRating: Double? { double("audienceRating") }
    var ratingImage: String? { string("ratingImage") }
    var audienceRatingImage: String? { string("audienceRatingImage") }
    var subtype: String? { string("subtype") }
    var extraType: Int? { int("extraType") }

    var genres: [String] { tags("Genre") }
    var directors: [String] { tags("Director") }
    var media: [PlexMedia] { list("Media").map(PlexMedia.init) }
    var markers: [PlexMarker] { list("Marker").map(PlexMarker.init) }
    var chapters: [PlexChapter] { list("Chapter").map(PlexChapter.init) }
    var roles: [PlexPerson] { list("Role").map { PlexPerson(raw: $0, kind: .actor) } }
    var crew: [PlexPerson] {
        list("Director").map { PlexPerson(raw: $0, kind: .director) }
            + list("Writer").map { PlexPerson(raw: $0, kind: .writer) }
            + list("Producer").map { PlexPerson(raw: $0, kind: .producer) }
    }
    var images: [JSON] { list("Image") }
    var clearLogo: String? { images.first { $0["type"] as? String == "clearLogo" }?["url"] as? String }
    var guids: [String: String] {
        var out: [String: String] = [:]
        for g in list("Guid") {
            guard let id = g["id"] as? String, let r = id.range(of: "://") else { continue }
            out[String(id[..<r.lowerBound])] = String(id[r.upperBound...])
        }
        return out
    }
    var ratings: [JSON] { list("Rating") }
    var extras: [PlexItem] { ((raw["Extras"] as? JSON)?["Metadata"] as? [JSON] ?? []).map(PlexItem.init) }
    var onDeck: PlexItem? { ((raw["OnDeck"] as? JSON)?["Metadata"] as? [JSON])?.first.map(PlexItem.init) }

    var isWatched: Bool {
        if type == "show" || type == "season" { return (leafCount ?? 0) > 0 && (viewedLeafCount ?? 0) >= (leafCount ?? 0) }
        return viewCount > 0
    }
    var progress: Double? {
        guard let d = durationMs, d > 0, viewOffsetMs > 0 else { return nil }
        return min(1, Double(viewOffsetMs) / Double(d))
    }
    var isPlayable: Bool { type == "movie" || type == "episode" || type == "clip" }

    /// "S1 · E3" for episodes.
    var episodeLabel: String? {
        guard type == "episode" else { return nil }
        return "S\(parentIndex ?? 0) · E\(index ?? 0)"
    }

    /// Wide artwork for backdrops and Continue Watching cards.
    var backdropPath: String? { art ?? grandparentArt ?? thumb }
    /// Poster-shaped artwork; episodes use their show's poster.
    var posterPath: String? { type == "episode" ? (grandparentThumb ?? parentThumb ?? thumb) : (thumb ?? parentThumb) }
    var displayTitle: String { type == "episode" ? (grandparentTitle ?? title) : title }

    static func == (a: PlexItem, b: PlexItem) -> Bool { a.id == b.id && a.viewOffsetMs == b.viewOffsetMs && a.viewCount == b.viewCount }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PlexMedia: PlexObject {
    let raw: JSON
    var id: Int? { int("id") }
    var container: String? { string("container") }
    var videoResolution: String? { string("videoResolution") }
    var width: Int? { int("width") }
    var height: Int? { int("height") }
    var bitrate: Int? { int("bitrate") }
    var videoCodec: String? { string("videoCodec") }
    var audioCodec: String? { string("audioCodec") }
    var audioChannels: Int? { int("audioChannels") }
    var videoProfile: String? { string("videoProfile") }
    var parts: [PlexPart] { list("Part").map(PlexPart.init) }
    var part: PlexPart? { parts.first }

    /// One line describing the version, for the version picker.
    var label: String {
        var bits: [String] = []
        if let r = videoResolution { bits.append(r.lowercased() == "4k" ? "4K" : r.uppercased().hasSuffix("P") ? r.uppercased() : r + "p") }
        if let v = part?.videoStream { bits.append(Decide.hdrLabel(v)) }
        if let c = videoCodec { bits.append(c.uppercased()) }
        if let a = part?.audioStreams.first { bits.append(a.displayTitle) }
        if let b = bitrate { bits.append(String(format: "%.1f Mbps", Double(b) / 1000)) }
        return bits.joined(separator: " · ")
    }
}

struct PlexPart: PlexObject {
    let raw: JSON
    var id: Int? { int("id") }
    var key: String? { string("key") }
    var file: String? { string("file") }
    var size: Int64? { (raw["size"] as? NSNumber)?.int64Value ?? string("size").flatMap { Int64($0) } }
    var container: String? { string("container") }
    var indexes: String? { string("indexes") }
    var streams: [PlexStream] { list("Stream").map(PlexStream.init) }

    func streams(type: Int) -> [PlexStream] {
        // External files have no container index; list them after the embedded ones.
        streams.filter { $0.streamType == type }.sorted { ($0.index ?? 1_000_000) < ($1.index ?? 1_000_000) }
    }
    var videoStream: PlexStream? { streams(type: 1).first }
    var audioStreams: [PlexStream] { streams(type: 2) }
    var subtitleStreams: [PlexStream] { streams(type: 3) }
}

struct PlexStream: PlexObject, Identifiable, @unchecked Sendable {
    let raw: JSON
    var id: Int { int("id") ?? -1 }
    var streamType: Int { int("streamType") ?? 0 }
    /// Position of the stream inside the container (FFmpeg's stream index). nil for external subtitle files.
    var index: Int? { int("index") }
    var codec: String { (string("codec") ?? "").lowercased() }
    var languageCode: String? { string("languageCode") }
    var language: String? { string("language") }
    var title: String? { string("title") }
    var channels: Int { int("channels") ?? 0 }
    var selected: Bool { bool("selected") }
    var forced: Bool { bool("forced") }
    var hearingImpaired: Bool { bool("hearingImpaired") }
    var isDefault: Bool { bool("default") }
    var key: String? { string("key") }
    var isExternal: Bool { key != nil && index == nil }
    var displayTitle: String { string("displayTitle") ?? codec.uppercased() }
    var extendedDisplayTitle: String { string("extendedDisplayTitle") ?? displayTitle }
    var profile: String? { string("profile") }
    var bitrate: Int? { int("bitrate") }
    var bitDepth: Int? { int("bitDepth") }
    var frameRate: Double? { double("frameRate") }
    var colorTrc: String? { string("colorTrc") }
    var colorPrimaries: String? { string("colorPrimaries") }
    var doviPresent: Bool { bool("DOVIPresent") }
    var doviProfile: Int? { int("DOVIProfile") }
    var doviBLCompatID: Int? { int("DOVIBLCompatID") }
    var samplingRate: Int? { int("samplingRate") }
    var audioChannelLayout: String? { string("audioChannelLayout") }
}

struct PlexMarker: PlexObject {
    let raw: JSON
    var type: String { string("type") ?? "" }
    var start: TimeInterval { Double(int("startTimeOffset") ?? 0) / 1000 }
    var end: TimeInterval { Double(int("endTimeOffset") ?? 0) / 1000 }
    var isIntro: Bool { type == "intro" }
    var isCredits: Bool { type == "credits" }
}

struct PlexChapter: PlexObject {
    let raw: JSON
    var title: String { string("tag") ?? "Chapter \(int("index") ?? 0)" }
    var start: TimeInterval { Double(int("startTimeOffset") ?? 0) / 1000 }
    var end: TimeInterval { Double(int("endTimeOffset") ?? 0) / 1000 }
    var thumb: String? { string("thumb") }
}

struct PlexPerson: PlexObject, Identifiable, Hashable, @unchecked Sendable {
    enum Kind: String { case actor, director, writer, producer
        var label: String {
            switch self {
            case .actor: return "Actor"
            case .director: return "Director"
            case .writer: return "Writer"
            case .producer: return "Producer"
            }
        }
    }
    let raw: JSON
    let kind: Kind
    var id: String { "\(kind.rawValue):\(tagId ?? name)" }
    var tagId: String? { string("id") }
    var name: String { string("tag") ?? "" }
    var role: String? { string("role") }
    var thumb: String? { string("thumb") }
    static func == (a: PlexPerson, b: PlexPerson) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PlexSection: PlexObject, Identifiable, Hashable, @unchecked Sendable {
    let raw: JSON
    var id: String { string("key") ?? "" }
    var title: String { string("title") ?? "" }
    var type: String { string("type") ?? "" }
    var isVideo: Bool { type == "movie" || type == "show" }
    static func == (a: PlexSection, b: PlexSection) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PlexServer: Codable, Equatable {
    var name: String
    var uri: String
    var token: String
    var machineId: String
    var relay: Bool
}

struct PlexUser: Codable, Equatable {
    var title: String
    var thumb: String?
    var uuid: String?
}
