import Foundation

/// What the Apple TV remembers per title, on top of what Plex stores: the resume point (kept even if the server didn't
/// get the last progress report, or for a Plex Home user without sync), the version, the audio track, the subtitle and
/// a downloaded online subtitle.
@MainActor
final class TitleMemory {
    static let shared = TitleMemory()

    struct Record: Codable {
        var at: Double = 0            // last change, seconds since 1970
        var position: Double?         // seconds
        var positionAt: Double?
        var mediaIndex: Int?
        var audioId: Int?
        var subtitleId: Int?          // Plex stream id; -1 = subtitles off
        var onlineSubtitle: String?   // file name in the subtitle cache
    }

    private let maxRecords = 400
    private var data: [String: Record]
    private var dirty = false
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("title-memory.json")
        data = (try? JSONDecoder().decode([String: Record].self, from: Data(contentsOf: url))) ?? [:]
        // Also mirrored to UserDefaults: tvOS may purge Caches when space runs low.
        if data.isEmpty, let d = UserDefaults.standard.data(forKey: "titleMemory") {
            data = (try? JSONDecoder().decode([String: Record].self, from: d)) ?? [:]
        }
    }

    private func key(_ item: PlexItem) -> String { "\(PlexClient.shared.server?.machineId ?? ""):\(item.ratingKey ?? "")" }

    func record(_ item: PlexItem) -> Record { data[key(item)] ?? Record() }

    func update(_ item: PlexItem, _ change: (inout Record) -> Void) {
        var r = record(item)
        change(&r)
        r.at = Date().timeIntervalSince1970
        data[key(item)] = r
        if data.count > maxRecords, let oldest = data.min(by: { $0.value.at < $1.value.at })?.key { data[oldest] = nil }
        dirty = true
    }

    /// Near the start or the end there's nothing to resume.
    func savePosition(_ item: PlexItem, _ time: TimeInterval, duration: TimeInterval) {
        update(item) { r in
            r.positionAt = Date().timeIntervalSince1970
            r.position = (time < 15 || (duration > 0 && time / duration > 0.92)) ? nil : time
        }
    }

    /// Whichever is newer: the Apple TV's own record or the server's.
    func resumePosition(_ item: PlexItem) -> TimeInterval {
        let server = Double(item.viewOffsetMs) / 1000
        let r = record(item)
        guard let at = r.positionAt else { return server }
        let serverAt = Double(item.lastViewedAt ?? 0)
        return at > serverAt + 30 ? (r.position ?? 0) : server
    }

    func flush() {
        guard dirty, let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: url, options: .atomic)
        UserDefaults.standard.set(d, forKey: "titleMemory")
        dirty = false
    }
}
