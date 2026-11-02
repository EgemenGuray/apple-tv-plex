import Compression
import Foundation

/// The TV guide: XMLTV files (plain or .gz), read as a stream and trimmed to the channels in the playlists and to
/// the catch-up window plus the next days.
final class XMLTVParser: NSObject, XMLParserDelegate {
    /// Guide channel id (lower case) → programmes, sorted by start.
    private(set) var programmes: [String: [IPTVProgramme]] = [:]
    /// Normalised display name → guide channel id, for playlists without tvg-id.
    private(set) var names: [String: String] = [:]
    /// Guide channel id → channel icon (logo) address.
    private(set) var icons: [String: String] = [:]

    private let wantedIDs: Set<String>
    private let wantedNames: Set<String>
    private let from: Date
    private let to: Date
    private var kept = Set<String>()

    private var element = ""
    private var text = ""
    private var channelID: String?
    private var channelNames: [String] = []
    private var channelIcon: String?
    private var current: IPTVProgramme?

    init(wantedIDs: Set<String>, wantedNames: Set<String>, from: Date, to: Date) {
        self.wantedIDs = wantedIDs
        self.wantedNames = wantedNames
        self.from = from
        self.to = to
    }

    static func parse(_ data: Data, wantedIDs: Set<String>, wantedNames: Set<String>, from: Date, to: Date) -> XMLTVParser {
        let p = XMLTVParser(wantedIDs: wantedIDs, wantedNames: wantedNames, from: from, to: to)
        let body = Gzip.isCompressed(data) ? (Gzip.decompress(data) ?? Data()) : data
        let x = XMLParser(data: body)
        x.delegate = p
        x.shouldResolveExternalEntities = false
        x.parse()
        for k in p.programmes.keys { p.programmes[k]?.sort { $0.start < $1.start } }
        return p
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        element = name
        text = ""
        switch name {
        case "channel":
            channelID = a["id"]?.lowercased()
            channelNames = []
            channelIcon = nil
        case "programme":
            guard let ch = a["channel"]?.lowercased(), kept.contains(ch) || wantedIDs.contains(ch),
                  let s = a["start"].flatMap(XMLTVParser.date), let e = a["stop"].flatMap(XMLTVParser.date) ?? Optional(s.addingTimeInterval(3600)),
                  e > from, s < to else { current = nil; return }
            current = IPTVProgramme(channel: ch, start: s, end: e, title: "")
        case "icon":
            if current != nil { current?.icon = a["src"] } else if channelID != nil, channelIcon == nil { channelIcon = a["src"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "display-name":
            if channelID != nil, !t.isEmpty { channelNames.append(t) }
        case "channel":
            if let id = channelID {
                let keys = channelNames.map(\.iptvKey)
                if wantedIDs.contains(id) || keys.contains(where: wantedNames.contains) {
                    kept.insert(id)
                    if let icon = channelIcon, !icon.isEmpty { icons[id] = icon }
                }
                for k in keys where names[k] == nil { names[k] = id }
            }
            channelID = nil
        case "title":
            if current != nil, current?.title.isEmpty == true { current?.title = t }
        case "sub-title":
            if current != nil, current?.episode == nil, !t.isEmpty { current?.episode = t }
        case "desc":
            if current != nil, current?.desc == nil { current?.desc = t }
        case "category":
            if current != nil, current?.category == nil { current?.category = t }
        case "episode-num":
            // xmltv_ns "1.4.0/1" → S2 E5; onscreen values are kept as they are.
            if current != nil, !t.isEmpty {
                let parts = t.split(separator: ".", omittingEmptySubsequences: false)
                if parts.count >= 2, let s = Int(parts[0].split(separator: "/").first ?? ""), let e = Int(parts[1].split(separator: "/").first ?? "") {
                    let label = "S\(s + 1) E\(e + 1)"
                    let existing = current?.episode
                    current?.episode = existing.map { "\(label) · \($0)" } ?? label
                } else if current?.episode == nil {
                    current?.episode = t
                }
            }
        case "programme":
            if let p = current { programmes[p.channel, default: []].append(p) }
            current = nil
        default: break
        }
        text = ""
    }

    /// "20250101120000 +0100" (seconds and offset optional).
    static func date(_ s: String) -> Date? {
        let chars = Array(s.trimmingCharacters(in: .whitespaces))
        guard chars.count >= 12 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? { a + n <= chars.count ? Int(String(chars[a..<a + n])) : nil }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2) else { return nil }
        let sec = chars.count >= 14 ? (num(12, 2) ?? 0) : 0
        var offset = 0
        if let signIdx = chars.firstIndex(where: { $0 == "+" || $0 == "-" }), signIdx + 5 <= chars.count,
           let oh = Int(String(chars[signIdx + 1..<signIdx + 3])), let om = Int(String(chars[signIdx + 3..<signIdx + 5])) {
            offset = (oh * 3600 + om * 60) * (chars[signIdx] == "-" ? -1 : 1)
        }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = sec
        c.timeZone = TimeZone(secondsFromGMT: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let utc = cal.date(from: c) else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
    }
}

/// gzip (.xml.gz guides) via Apple's Compression framework, which reads raw DEFLATE.
enum Gzip {
    static func isCompressed(_ d: Data) -> Bool { d.count > 18 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b }

    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= bytes.count else { return nil }; i += 2 + (Int(bytes[i]) | (Int(bytes[i + 1]) << 8)) }
        if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < bytes.count - 8 else { return nil }

        let deflate = Array(bytes[i..<(bytes.count - 8)])
        var out = Data()
        let bufSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        return deflate.withUnsafeBufferPointer { src -> Data? in
            guard let base = src.baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: bufSize - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return out
                default: return out.isEmpty ? nil : out
                }
            }
        }
    }
}
