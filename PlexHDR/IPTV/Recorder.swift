import Foundation
import SwiftUI

/// Downloads (films, episodes, catch-up programmes) and recordings (live channels, now or scheduled from the guide).
/// Streams are written straight to disk as they arrive; HLS channels are recorded segment by segment.
/// Recordings run while Lumen is open. Apple TV only has cache storage, which tvOS may clear when space runs low.
@MainActor
final class IPTVRecorder: ObservableObject {
    static let shared = IPTVRecorder()

    struct Job: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case download, recording }
        enum State: String, Codable { case scheduled, running, done, failed, cancelled }
        var id = UUID()
        var kind: Kind
        var title: String
        var subtitle: String?
        var poster: String?
        var url: String
        var userAgent: String?
        var file: String
        var start: Date
        var end: Date?
        var state: State = .scheduled
        var received: Int64 = 0
        var expected: Int64?
        var error: String?
        var channelID: String?
        var created = Date()

        var progress: Double? {
            if let e = expected, e > 0 { return min(1, Double(received) / Double(e)) }
            if let end, state == .running { return min(1, max(0, Date().timeIntervalSince(start) / end.timeIntervalSince(start))) }
            return nil
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var writers: [UUID: StreamWriter] = [:]
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "iptv.jobs"), let j = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = j.map { var x = $0; if x.state == .running { x.state = .failed; x.error = "Interrupted when Lumen closed." }; return x }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in IPTVRecorder.shared.tick() }
        }
        tick()
    }

    var downloads: [Job] { jobs.filter { $0.kind == .download }.sorted { $0.created > $1.created } }
    var recordings: [Job] { jobs.filter { $0.kind == .recording }.sorted { $0.start > $1.start } }
    var usedBytes: Int64 { jobs.filter { $0.state != .scheduled }.reduce(0) { $0 + $1.received } }

    static var directory: URL {
        let fm = FileManager.default
        #if os(tvOS)
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #elseif os(macOS)
        let base = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        #else
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func fileURL(_ j: Job) -> URL { Self.directory.appendingPathComponent(j.file) }

    // MARK: - Adding

    func download(movie m: IPTVMovie) {
        add(Job(kind: .download, title: m.name, subtitle: m.year.map(String.init), poster: m.poster, url: m.url,
                userAgent: IPTVStore.shared.playlist(m.playlistID)?.userAgent, file: fileName(m.name, m.url), start: Date()))
    }

    func download(episode e: IPTVEpisode, of s: IPTVSeries) {
        add(Job(kind: .download, title: "\(s.name) · \(e.label)", subtitle: e.title, poster: e.thumb ?? s.poster, url: e.url,
                userAgent: IPTVStore.shared.playlist(s.playlistID)?.userAgent, file: fileName("\(s.name) \(e.label)", e.url), start: Date()))
    }

    /// A past programme, saved from the channel's catch-up.
    func download(catchup p: IPTVProgramme, on ch: IPTVChannel) {
        guard let url = IPTVStore.shared.catchupURL(ch, p) else { return }
        add(Job(kind: .download, title: p.title, subtitle: "\(ch.name) · \(IPTVFormat.day(p.start)) \(p.timeRange)", poster: ch.logo, url: url,
                userAgent: ch.userAgent, file: fileName("\(ch.name) \(p.title)", url, ext: "ts"), start: Date(), end: Date().addingTimeInterval(p.duration + 600),
                channelID: ch.id))
    }

    /// Records a programme (from a minute before to two minutes after), or the channel from now for `minutes`.
    func record(_ ch: IPTVChannel, programme p: IPTVProgramme? = nil, minutes: Int = 60) {
        let start = p.map { max(Date(), $0.start.addingTimeInterval(-60)) } ?? Date()
        let end = p.map { $0.end.addingTimeInterval(120) } ?? Date().addingTimeInterval(TimeInterval(minutes * 60))
        let title = p?.title ?? ch.name
        let sub = "\(ch.name) · \(IPTVFormat.day(start)) \(IPTVFormat.time(start)) – \(IPTVFormat.time(end))"
        add(Job(kind: .recording, title: title, subtitle: sub, poster: ch.logo, url: ch.url, userAgent: ch.userAgent,
                file: fileName("\(ch.name) \(title)", ch.url, ext: "ts"), start: start, end: end, channelID: ch.id))
    }

    func isRecording(_ ch: IPTVChannel, _ p: IPTVProgramme) -> Bool {
        jobs.contains { $0.kind == .recording && $0.channelID == ch.id && ($0.state == .scheduled || $0.state == .running)
            && $0.start <= p.start.addingTimeInterval(60) && ($0.end ?? .distantFuture) >= p.end }
    }

    func isRecording(channel ch: IPTVChannel) -> Job? {
        jobs.first { $0.kind == .recording && $0.channelID == ch.id && $0.state == .running }
    }

    private func add(_ j: Job) {
        jobs.append(j)
        persist()
        tick()
    }

    private func fileName(_ title: String, _ url: String, ext: String? = nil) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ").prefix(80)
        let e = ext ?? {
            let x = (URL(string: url)?.pathExtension ?? "").lowercased()
            return ["mp4", "mkv", "avi", "mov", "m4v", "ts", "webm"].contains(x) ? x : "ts"
        }()
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(safe) \(stamp).\(e)"
    }

    // MARK: - Running

    /// Starts due jobs and stops finished recordings.
    func tick() {
        let now = Date()
        for j in jobs where j.state == .scheduled && j.start <= now {
            if let end = j.end, end <= now { update(j.id) { $0.state = .failed; $0.error = "Lumen wasn't open at the scheduled time." }; continue }
            begin(j)
        }
        for j in jobs where j.state == .running {
            if let end = j.end, end <= now { stop(j.id, state: .done) }
        }
    }

    private func begin(_ j: Job) {
        update(j.id) { $0.state = .running; $0.received = 0; $0.error = nil }
        let file = fileURL(j)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let url = URL(string: j.url) else { update(j.id) { $0.state = .failed; $0.error = "No address." }; return }
        let id = j.id
        if url.path.lowercased().hasSuffix(".m3u8") {
            hlsTasks[id] = Task { [weak self] in await self?.recordHLS(id: id, url: url, userAgent: j.userAgent, file: file, until: j.end) }
            return
        }
        let w = StreamWriter(file: file) { [weak self] received, expected in
            Task { @MainActor in self?.update(id) { $0.received = received; if let expected { $0.expected = expected } } }
        } done: { [weak self] error in
            Task { @MainActor in self?.finished(id, error: error) }
        }
        writers[id] = w
        var req = URLRequest(url: url)
        if let ua = j.userAgent, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        w.start(req)
    }

    private func finished(_ id: UUID, error: Error?) {
        writers[id] = nil
        guard let j = jobs.first(where: { $0.id == id }), j.state == .running else { return }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            // A live recording that drops before its end time reconnects and keeps appending.
            if j.kind == .recording, let end = j.end, end > Date() {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.resume(id)
                }
                return
            }
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        } else if j.kind == .recording, let end = j.end, end > Date().addingTimeInterval(30) {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.resume(id)
            }
            return
        } else {
            update(id) { $0.state = .done }
        }
    }

    /// Reconnects a running recording, appending to the same file.
    private func resume(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }), j.state == .running, let url = URL(string: j.url) else { return }
        let base = j.received
        let w = StreamWriter(file: fileURL(j), append: true) { [weak self] received, _ in
            Task { @MainActor in self?.update(id) { $0.received = base + received } }
        } done: { [weak self] error in
            Task { @MainActor in self?.finished(id, error: error) }
        }
        writers[id] = w
        var req = URLRequest(url: url)
        if let ua = j.userAgent, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        w.start(req)
    }

    func stop(_ id: UUID, state: Job.State = .cancelled) {
        writers[id]?.cancel()
        writers[id] = nil
        hlsTasks[id]?.cancel()
        hlsTasks[id] = nil
        update(id) {
            // A stopped recording keeps what it has; a stopped download is incomplete.
            if $0.kind == .recording && $0.received > 0 { $0.state = .done } else { $0.state = state }
            if $0.kind == .recording { $0.end = min($0.end ?? Date(), Date()) }
        }
    }

    func retry(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        if j.kind == .recording, let end = j.end, end <= Date() { return }
        update(id) { $0.state = .scheduled; $0.start = min($0.start, Date()) }
        tick()
    }

    func delete(_ id: UUID) {
        stop(id)
        if let j = jobs.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: fileURL(j)) }
        jobs.removeAll { $0.id == id }
        persist()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let before = jobs[i].state
        change(&jobs[i])
        // Progress changes often; only state changes are saved.
        if jobs[i].state != before { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: "iptv.jobs") }
    }

    // MARK: - HLS

    private func recordHLS(id: UUID, url: URL, userAgent: String?, file: URL, until end: Date?) async {
        var seen = Set<String>()
        var mediaURL = url
        var wroteInit = false
        var total: Int64 = 0
        func get(_ u: URL) async throws -> Data {
            var req = URLRequest(url: u, timeoutInterval: 30)
            if let userAgent, !userAgent.isEmpty { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            return try await URLSession.shared.data(for: req).0
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { update(id) { $0.state = .failed; $0.error = "Can't write the file." }; return }
        defer { try? handle.close() }
        var failures = 0
        while !Task.isCancelled {
            if let end, Date() >= end { break }
            do {
                let body = try await get(mediaURL)
                let text = String(decoding: body, as: UTF8.self)
                let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                // Master playlist: take the highest bandwidth variant.
                if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
                    var best: (Int, URL)?
                    for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
                        let bw = Int(l.components(separatedBy: "BANDWIDTH=").dropFirst().first?.prefix { $0.isNumber } ?? "") ?? 0
                        if let next = lines[safe: i + 1], !next.isEmpty, let u = URL(string: next, relativeTo: mediaURL)?.absoluteURL, bw >= (best?.0 ?? -1) { best = (bw, u) }
                    }
                    if let b = best { mediaURL = b.1; continue }
                }
                var target = 6.0
                for l in lines {
                    if l.hasPrefix("#EXT-X-TARGETDURATION:") { target = Double(l.dropFirst(22)) ?? 6 }
                    if l.hasPrefix("#EXT-X-MAP:"), !wroteInit, let r = l.range(of: "URI=\"") {
                        let rest = l[r.upperBound...]
                        if let q = rest.firstIndex(of: "\""), let u = URL(string: String(rest[..<q]), relativeTo: mediaURL) {
                            let d = try await get(u.absoluteURL)
                            try handle.write(contentsOf: d)
                            total += Int64(d.count)
                            wroteInit = true
                        }
                    }
                }
                for l in lines where !l.isEmpty && !l.hasPrefix("#") {
                    guard let u = URL(string: l, relativeTo: mediaURL)?.absoluteURL, seen.insert(u.absoluteString).inserted else { continue }
                    let d = try await get(u)
                    try handle.write(contentsOf: d)
                    total += Int64(d.count)
                    let t = total
                    update(id) { $0.received = t }
                }
                failures = 0
                if lines.contains("#EXT-X-ENDLIST") { break }
                try await Task.sleep(nanoseconds: UInt64(max(1, target / 2) * 1_000_000_000))
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                if failures > 10 { update(id) { $0.state = .failed; $0.error = error.localizedDescription }; return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        hlsTasks[id] = nil
        update(id) { if $0.state == .running { $0.state = .done } }
    }
}

/// Writes an HTTP response body to a file as it arrives.
final class StreamWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let append: Bool
    private var handle: FileHandle?
    private var session: URLSession?
    private var received: Int64 = 0
    private var expected: Int64?
    private var lastReport = Date.distantPast
    private var httpError: Error?
    private let progress: (Int64, Int64?) -> Void
    private let done: (Error?) -> Void

    init(file: URL, append: Bool = false, progress: @escaping (Int64, Int64?) -> Void, done: @escaping (Error?) -> Void) {
        self.file = file
        self.append = append
        self.progress = progress
        self.done = done
    }

    func start(_ req: URLRequest) {
        handle = try? FileHandle(forWritingTo: file)
        if append { _ = try? handle?.seekToEnd() } else { try? handle?.truncate(atOffset: 0) }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 86400
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session?.dataTask(with: req).resume()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            httpError = IPTVError.message("The server answered \(h.statusCode).")
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 { expected = response.expectedContentLength }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 1 {
            lastReport = Date()
            progress(received, expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        progress(received, expected)
        session.finishTasksAndInvalidate()
        done(httpError ?? error)
    }
}
