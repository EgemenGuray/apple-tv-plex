import Foundation

/// Addresses for past programmes. Supports the M3U `catchup` modes players commonly use (default with a
/// `catchup-source` template, append, shift/timeshift, flussonic) and Xtream Codes timeshift.
enum Catchup {
    static func url(channel ch: IPTVChannel, programme p: IPTVProgramme, playlist: IPTVPlaylist?, content: IPTVContent?) -> String? {
        guard let c = ch.catchup else { return nil }
        let now = Date()
        let end = min(p.end, now)
        let mode = c.mode.lowercased()

        if mode == "xc" || mode == "xtream" {
            let minutes = max(1, Int((p.end.timeIntervalSince(p.start) / 60).rounded(.up)))
            let tz = content?.serverTimeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
            if let playlist, playlist.kind == .xtream, let id = ch.streamID {
                return XtreamClient(playlist: playlist).timeshiftURL(id, start: p.start, minutes: minutes, timeZone: tz)
            }
            // An M3U from an Xtream server: http://host/(live/)user/pass/<id>.<ext>
            guard let u = URL(string: ch.url), let host = u.host else { return nil }
            var parts = u.path.split(separator: "/").map(String.init)
            if parts.first == "live" { parts.removeFirst() }
            guard parts.count >= 3, let id = Int((parts[2] as NSString).deletingPathExtension) else { return nil }
            let base = "\(u.scheme ?? "http")://\(host)\(u.port.map { ":\($0)" } ?? "")"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = "yyyy-MM-dd:HH-mm"
            return "\(base)/timeshift/\(parts[0])/\(parts[1])/\(minutes)/\(f.string(from: p.start))/\(id).ts"
        }

        switch mode {
        case "append":
            guard let src = c.source else { return nil }
            return ch.url + fill(src, start: p.start, end: end, now: now)
        case "shift", "timeshift":
            let sep = ch.url.contains("?") ? "&" : "?"
            return ch.url + sep + "utc=\(Int(p.start.timeIntervalSince1970))&lutc=\(Int(now.timeIntervalSince1970))"
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            let start = Int(p.start.timeIntervalSince1970)
            let dur = Int(end.timeIntervalSince(p.start))
            if let r = ch.url.range(of: #"/(index|video|mono)[^/]*\.m3u8"#, options: .regularExpression) {
                var u = ch.url
                u.replaceSubrange(r, with: "/index-\(start)-\(dur).m3u8")
                return u
            }
            if let r = ch.url.range(of: #"/mpegts(\?|$)"#, options: .regularExpression) {
                var u = ch.url
                u.replaceSubrange(r, with: "/timeshift_abs-\(start).ts" + (ch.url[r].hasSuffix("?") ? "?" : ""))
                return u
            }
            return nil
        default:
            if let src = c.source, !src.isEmpty {
                let filled = fill(src, start: p.start, end: end, now: now)
                // A relative template is appended to the live address.
                return filled.lowercased().hasPrefix("http") ? filled : ch.url + filled
            }
            let sep = ch.url.contains("?") ? "&" : "?"
            return ch.url + sep + "utc=\(Int(p.start.timeIntervalSince1970))&lutc=\(Int(now.timeIntervalSince1970))"
        }
    }

    /// Fills {utc} {start} {utcend} {end} {lutc} {now} {timestamp} {duration} {offset} {Y} {m} {d} {H} {M} {S}
    /// (also written ${...}), plus {duration:N} and {offset:N} divided by N.
    static func fill(_ template: String, start: Date, end: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        let n = Int(now.timeIntervalSince1970)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let values: [String: String] = [
            "utc": "\(s)", "start": "\(s)", "timestamp": "\(n)", "utcend": "\(e)", "end": "\(e)",
            "lutc": "\(n)", "now": "\(n)", "duration": "\(e - s)", "offset": "\(n - s)",
            "Y": "\(c.year ?? 1970)", "m": two(c.month), "d": two(c.day), "H": two(c.hour), "M": two(c.minute), "S": two(c.second),
        ]
        var out = template
        if let re = try? NSRegularExpression(pattern: #"\$?\{(duration|offset):(\d+)\}"#) {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let r = Range(m.range, in: out), let kr = Range(m.range(at: 1), in: out), let dr = Range(m.range(at: 2), in: out),
                      let div = Int(out[dr]), div > 0 else { continue }
                let base = out[kr] == "duration" ? e - s : n - s
                out.replaceSubrange(r, with: "\(base / div)")
            }
        }
        for (k, v) in values {
            out = out.replacingOccurrences(of: "${\(k)}", with: v).replacingOccurrences(of: "{\(k)}", with: v)
        }
        return out
    }
}
