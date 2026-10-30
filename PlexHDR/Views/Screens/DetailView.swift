import SwiftUI

/// Movie or episode details: logo, metadata, badges, ratings, what Play will do, actions, then chapters, the rest of
/// the season, cast & crew, extras and more like this.
struct DetailView: View {
    let item: PlexItem
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var settings: AppSettings
    @State private var full: PlexItem?
    @State private var ratings: Online.Ratings?
    @State private var season: [PlexItem] = []
    @State private var similar: [PlexItem] = []
    @State private var mediaIndex = 0
    @State private var audioId: Int?
    @State private var subtitleId: Int??
    @State private var sheet: Sheet?
    @State private var watched = false

    enum Sheet: String, Identifiable { case tracks, version, info; var id: String { rawValue } }

    private var it: PlexItem { full ?? item }
    private var plan: Decide.Plan { Decide.plan(it, mediaIndex: mediaIndex, audioId: audioId, subtitleId: subtitleId, settings: settings) }
    private var resume: TimeInterval { TitleMemory.shared.resumePosition(it) }

    var body: some View {
        ZStack {
            Backdrop(item: it)
            ScrollView {
                VStack(alignment: .leading, spacing: 50) {
                    header.frame(minHeight: 900, alignment: .bottomLeading)
                    rows
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea(edges: .top)
        .task { await load() }
        .onChange(of: presenter.playbackEnded) { _, _ in Task { await load() } }
        .sheet(item: $sheet) { s in
            switch s {
            case .tracks: TrackPicker(plan: plan, audioId: $audioId, subtitleId: $subtitleId, item: it)
            case .version: VersionPicker(item: it, mediaIndex: $mediaIndex)
            case .info: TechInfo(item: it, plan: plan)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 200)
            if it.type == "episode" {
                Text(it.grandparentTitle ?? "").font(.title3).foregroundStyle(.secondary)
                Text(it.title).font(.system(size: 64, weight: .heavy)).lineLimit(2)
            } else {
                TitleLogo(item: it)
            }
            HStack(spacing: 16) {
                if let ep = it.episodeLabel { Text(ep) }
                if let y = it.year { Text(String(y)) }
                if let r = it.contentRating { Badge(text: r) }
                if let d = formatDuration(it.durationMs) { Text(d) }
                if !it.genres.isEmpty { Text(it.genres.prefix(3).joined(separator: ", ")) }
                ForEach(Decide.badges(plan), id: \.self) { Badge(text: $0) }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let ratings, !ratings.isEmpty, settings.showRatings { RatingsRow(ratings: ratings) }
            if let t = it.tagline { Text(t).font(.headline) }
            Text(it.summary ?? "").font(.callout).lineLimit(4).frame(maxWidth: 1200, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.note)
                ForEach(plan.warnings, id: \.self) { Text("⚠︎ " + $0).foregroundStyle(.yellow) }
            }
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 1400, alignment: .leading)
            actions
        }
        .padding(.horizontal, 80)
    }

    private var actions: some View {
        HStack(spacing: 24) {
            Button { play(from: nil) } label: {
                Label(resume > 0 ? "Resume \(formatTime(resume))" : "Play", systemImage: "play.fill")
            }
            if resume > 0 {
                Button { play(from: 0) } label: { Label("Start Over", systemImage: "arrow.counterclockwise") }
            }
            if let trailer = it.extras.first(where: { $0.subtype == "trailer" || $0.extraType == 1 }) {
                Button { presenter.play(trailer, from: 0) } label: { Label("Trailer", systemImage: "film") }
            }
            Button { sheet = .tracks } label: { Label("Audio & Subtitles", systemImage: "captions.bubble") }
            if it.media.count > 1 {
                Button { sheet = .version } label: { Label("Version", systemImage: "square.stack") }
            }
            Button {
                watched.toggle()
                Task { await PlexClient.shared.setWatched(it, watched); await load() }
            } label: { Label(watched ? "Watched" : "Mark Watched", systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle") }
            Button { sheet = .info } label: { Image(systemName: "info.circle") }
        }
        .labelStyle(.titleAndIcon)
        .focusSection()
    }

    @ViewBuilder private var rows: some View {
        let chapters = it.chapters
        if chapters.count > 1 {
            VStack(alignment: .leading, spacing: 16) {
                Text("Chapters").font(.title3.bold()).padding(.leading, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(chapters.indices, id: \.self) { i in
                            let c = chapters[i]
                            Button { play(from: c.start) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    RemoteImage(url: PlexClient.shared.imageURL(c.thumb ?? it.thumb, width: 480, height: 270))
                                        .frame(width: 400, height: 225).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(c.title).font(.caption).lineLimit(1)
                                    Text(formatTime(c.start)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(width: 400, alignment: .leading)
                            }
                            .buttonStyle(LiftButtonStyle())
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
        if it.type == "episode", season.count > 1 {
            ItemRow(title: "Season \(it.parentIndex ?? 0)", items: season, wide: true)
        }
        CastRow(item: it)
        if !it.extras.isEmpty { ExtrasRow(extras: it.extras) }
        if !similar.isEmpty { ItemRow(title: "More Like This", items: similar) }
    }

    private func play(from start: TimeInterval?) {
        presenter.play(it, from: start, mediaIndex: mediaIndex, audioId: audioId, subtitleId: subtitleId)
    }

    private func load() async {
        guard let rk = item.ratingKey else { return }
        if let m = try? await PlexClient.shared.metadata(rk) { full = m }
        watched = it.isWatched
        let mem = TitleMemory.shared.record(it)
        if let m = mem.mediaIndex, it.media.indices.contains(m) { mediaIndex = m }
        if audioId == nil { audioId = mem.audioId }
        if subtitleId == nil, let s = mem.subtitleId { subtitleId = .some(s < 0 ? nil : s) }
        if it.type == "episode", let p = it.parentRatingKey { season = (try? await PlexClient.shared.children(p)) ?? [] }
        else { similar = await PlexClient.shared.similar(rk) }
        ratings = await Online.shared.ratings(it)
    }
}

/// Apple TV-style cast & crew: actors with their roles, then directors, writers and producers (one card per person).
struct CastRow: View {
    let item: PlexItem
    var body: some View {
        let people = merged
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cast & Crew").font(.title3.bold()).padding(.leading, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(people, id: \.person.id) { entry in
                            NavigationLink(value: Route.person(entry.person)) {
                                VStack(spacing: 10) {
                                    RemoteImage(url: PlexClient.shared.imageURL(entry.person.thumb, width: 300, height: 300))
                                        .overlay { if entry.person.thumb == nil { Text(initials(entry.person.name)).font(.title.bold()) } }
                                        .frame(width: 180, height: 180).clipShape(Circle())
                                    Text(entry.person.name).font(.caption).lineLimit(1)
                                    Text(entry.jobs).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: 200)
                            }
                            .buttonStyle(LiftButtonStyle())
                        }
                    }
                    .padding(.horizontal, 80).padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private struct Entry { let person: PlexPerson; let jobs: String }
    private var merged: [Entry] {
        var out = item.roles.map { Entry(person: $0, jobs: $0.role ?? "Actor") }
        var crewJobs: [(PlexPerson, [String])] = []
        for p in item.crew {
            if let i = crewJobs.firstIndex(where: { $0.0.name == p.name }) { crewJobs[i].1.append(p.kind.label) }
            else { crewJobs.append((p, [p.kind.label])) }
        }
        out += crewJobs.map { Entry(person: $0.0, jobs: $0.1.joined(separator: ", ")) }
        return out
    }
    private func initials(_ n: String) -> String { n.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
}

struct ExtrasRow: View {
    let extras: [PlexItem]
    @EnvironmentObject private var presenter: PlayerPresenter
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Extras").font(.title3.bold()).padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(extras) { e in
                        Button { presenter.play(e, from: 0) } label: { WideCard(item: e, width: 400) }
                            .buttonStyle(LiftButtonStyle())
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Sheets

struct TrackPicker: View {
    let plan: Decide.Plan
    @Binding var audioId: Int?
    @Binding var subtitleId: Int??
    let item: PlexItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            List {
                Section("Audio") {
                    ForEach(plan.part?.audioStreams ?? []) { s in
                        Button { audioId = s.id; save(); } label: {
                            row(s.extendedDisplayTitle, selected: plan.audio?.id == s.id)
                        }
                    }
                }
            }
            List {
                Section("Subtitles") {
                    Button { subtitleId = .some(nil); save() } label: { row("Off", selected: plan.subtitle == nil) }
                    ForEach(plan.part?.subtitleStreams ?? []) { s in
                        Button { subtitleId = .some(s.id); save() } label: {
                            row(s.extendedDisplayTitle + (s.isExternal ? " · External" : ""), selected: plan.subtitle?.id == s.id)
                        }
                    }
                }
            }
        }
        .padding(60)
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark") } }
    }

    private func save() {
        TitleMemory.shared.update(item) { r in
            r.audioId = audioId
            if let s = subtitleId { r.subtitleId = s ?? -1 }
        }
        if let pid = plan.part?.id {
            let sub: Int? = subtitleId.map { $0 ?? 0 }
            Task { await PlexClient.shared.selectStreams(partId: pid, audio: audioId, subtitle: sub) }
        }
    }
}

struct VersionPicker: View {
    let item: PlexItem
    @Binding var mediaIndex: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("Version") {
                ForEach(item.media.indices, id: \.self) { i in
                    Button {
                        mediaIndex = i
                        TitleMemory.shared.update(item) { $0.mediaIndex = i }
                        dismiss()
                    } label: {
                        HStack { Text(item.media[i].label); Spacer(); if i == mediaIndex { Image(systemName: "checkmark") } }
                    }
                }
            }
        }
        .padding(60)
    }
}

/// Full technical sheet.
struct TechInfo: View {
    let item: PlexItem
    let plan: Decide.Plan
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title).font(.title2.bold())
                if let f = plan.part?.file { line("File", (f as NSString).lastPathComponent) }
                if let s = plan.part?.size { line("Size", ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                if let c = plan.media?.container { line("Container", c.uppercased()) }
                if let b = plan.media?.bitrate { line("Bitrate", String(format: "%.1f Mbps", Double(b) / 1000)) }
                if let v = plan.video {
                    line("Video", v.extendedDisplayTitle)
                    line("Dynamic range", plan.hdr)
                    if let fr = v.frameRate { line("Frame rate", String(format: "%.3f fps", fr)) }
                    if let bd = v.bitDepth { line("Bit depth", "\(bd)-bit") }
                }
                ForEach(plan.part?.audioStreams ?? []) { a in line(a.id == plan.audio?.id ? "Audio ▶︎" : "Audio", a.extendedDisplayTitle) }
                ForEach(plan.part?.subtitleStreams ?? []) { s in line("Subtitle", s.extendedDisplayTitle + (Decide.isImageSub(s) ? " (image)" : "")) }
                line("Playback", plan.note)
                line("Output", AudioSetup.routeDescription)
            }
            .font(.callout)
            .padding(60)
        }
    }
    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary).frame(width: 260, alignment: .leading); Text(v) }
    }
}
