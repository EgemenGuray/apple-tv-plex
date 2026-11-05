import SwiftUI

/// Swipe-down panel with tabs: Audio & Subtitles (first), Chapters, Picture, Info.
struct PlayerPanel: View {
    @ObservedObject var c: PlayerController
    @FocusState private var focusedTab: PlayerController.Panel?

    var body: some View {
        VStack(alignment: .leading, spacing: 30.s) {
            HStack(spacing: 20.s) {
                ForEach(PlayerController.Panel.allCases) { p in
                    Button { c.panel = p } label: { Text(p.title).font(.callout.weight(.semibold)) }
                        .focused($focusedTab, equals: p)
                        .tint(c.panel == p ? .white : nil)
                        #if !os(tvOS)
                        .buttonStyle(.bordered)
                        #endif
                }
                if !Platform.isTV {
                    Spacer()
                    Button { c.panel = nil; c.hideOverlaySoon() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                }
            }
            .tvFocusSection()
            .disabled(c.adjustingDelay)
            .onChange(of: focusedTab) { _, t in if let t { c.panel = t } }

            Group {
                switch c.panel ?? .tracks {
                case .tracks: TracksTab(c: c).scrollsHorizontallyOnSmallScreens()
                case .chapters: ChaptersTab(c: c)
                case .picture: PictureTab(c: c)
                case .info: InfoTab(c: c)
                }
            }
            .frame(height: 360.s, alignment: .topLeading)
            .tvFocusSection()
        }
        .padding(.horizontal, 90.s).padding(.top, 40.s).padding(.bottom, 60.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .onAppear { focusedTab = c.panel }
        .onDisappear { c.adjustingDelay = false }
    }
}

private struct OptionButton: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 2.s) {
                    Text(title).font(.callout).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(width: 520.s, alignment: .leading)
        }
    }
}

private struct InfoTab: View {
    @ObservedObject var c: PlayerController
    var body: some View {
        HStack(alignment: .top, spacing: 50.s) {
            RemoteImage(url: PlexClient.shared.imageURL(c.item.posterPath, width: 300, height: 450)).frame(width: 200.s, height: 300.s)
                .clipShape(RoundedRectangle(cornerRadius: 10.s))
            VStack(alignment: .leading, spacing: 12.s) {
                Text(c.item.title).font(.title3.bold())
                Text(c.item.summary ?? "").font(.caption).lineLimit(4).frame(maxWidth: 1100.s, alignment: .leading)
                Text("Video: \(c.videoInfo)").font(.caption)
                Text("Audio: \(c.audioInfo)").font(.caption)
                Text("5.1, 7.1 and Dolby Atmos play as Spatial Audio on AirPods.").font(.caption2).foregroundStyle(.secondary)
                Text("Player: \(c.engineName) · \(c.plan.note)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 1300.s, alignment: .leading)
                // A focusable element so the tab's content can take focus.
                Button("Close") { c.panel = nil }
            }
        }
    }
}

private struct ChaptersTab: View {
    @ObservedObject var c: PlayerController
    var body: some View {
        let chapters = c.chapters
        if chapters.isEmpty {
            Text("This file has no chapters.").foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30.s) {
                    ForEach(chapters.indices, id: \.self) { i in
                        let ch = chapters[i]
                        Button { c.seek(to: ch.start); c.panel = nil } label: {
                            VStack(alignment: .leading, spacing: 6.s) {
                                Group {
                                    if let t = ch.thumb { RemoteImage(url: PlexClient.shared.imageURL(t, width: 480, height: 270)) }
                                    else if let img = c.bif?.image(at: ch.start + 5) { Image(uiImage: img).resizable().aspectRatio(contentMode: .fill) }
                                    else { Color.white.opacity(0.08) }
                                }
                                .frame(width: 360.s, height: 202.s).clipShape(RoundedRectangle(cornerRadius: 10.s))
                                Text(ch.title).font(.caption).lineLimit(1)
                                Text(formatTime(ch.start)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 360.s, alignment: .leading)
                        }
                        .buttonStyle(LiftButtonStyle())
                    }
                }
                .padding(.vertical, 20.s)
            }
            .scrollClipDisabled()
        }
    }
}

/// Audio on the left (with the file's other versions and the speed under it), subtitles on the right (Off, the
/// file's tracks, a downloaded one, Search Online… and the delay), and online results beside them after a search.
private struct TracksTab: View {
    @ObservedObject var c: PlayerController
    @State private var results: [Online.SubtitleResult] = []
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 50.s) {
            audioColumn.disabled(c.adjustingDelay)
            subtitleColumn
            if searching || !results.isEmpty || message != nil {
                VStack(alignment: .leading, spacing: 12.s) {
                    header("Online")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12.s) {
                            if searching { ProgressView() }
                            if let message { Text(message).font(.caption).foregroundStyle(.secondary).frame(width: 520.s, alignment: .leading) }
                            ForEach(results) { r in
                                OptionButton(title: r.title, subtitle: resultDetail(r), selected: false) { Task { await pick(r) } }
                            }
                        }
                        .padding(.vertical, 6.s)
                    }
                }
                .frame(width: 560.s)
                .disabled(c.adjustingDelay)
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var audioColumn: some View {
        VStack(alignment: .leading, spacing: 12.s) {
            header("Audio")
            ScrollView {
                VStack(alignment: .leading, spacing: 12.s) {
                    ForEach(c.plan.part?.audioStreams ?? []) { s in
                        OptionButton(title: Decide.audioTrackTitle(s), subtitle: Decide.audioTrackDetail(s),
                                     selected: c.plan.audio?.id == s.id) { c.chooseAudio(s) }
                    }
                    if c.hasOtherVersions {
                        header("Version").padding(.top, 14.s)
                        ForEach(Array(c.item.media.enumerated()), id: \.offset) { i, m in
                            OptionButton(title: m.label.isEmpty ? "Version \(i + 1)" : m.label,
                                         selected: c.plan.mediaIndex == i) { c.switchVersion(i) }
                        }
                    }
                    header("Speed").padding(.top, 14.s)
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                        OptionButton(title: r == 1 ? "Normal" : "\(r)×", selected: c.rate == r) { c.setRate(r) }
                    }
                }
                .padding(.vertical, 6.s)
            }
        }
        .frame(width: 560.s)
    }

    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 12.s) {
            header("Subtitles")
            ScrollView {
                VStack(alignment: .leading, spacing: 12.s) {
                    OptionButton(title: "Off", selected: c.plan.subtitle == nil && c.selectedOnlineSubtitle == nil) {
                        Task { await c.select(subtitle: nil) }
                    }
                    ForEach(c.plan.part?.subtitleStreams ?? []) { s in
                        OptionButton(title: Decide.subtitleTitle(s), subtitle: Decide.subtitleDetail(s),
                                     selected: c.selectedOnlineSubtitle == nil && c.plan.subtitle?.id == s.id) { Task { await c.select(subtitle: s) } }
                    }
                    if let name = c.selectedOnlineSubtitle {
                        OptionButton(title: "Downloaded", subtitle: name, selected: true) {}
                    }
                    Button { Task { await search() } } label: {
                        Label("Search Online…", systemImage: "magnifyingglass").font(.callout).frame(width: 520.s, alignment: .leading)
                    }
                }
                .padding(.vertical, 6.s)
            }
            .disabled(c.adjustingDelay)
            DelayRow(c: c)
        }
        .frame(width: 560.s)
    }

    private func resultDetail(_ r: Online.SubtitleResult) -> String {
        var bits = [r.source == "plex" ? "Plex server" : "OpenSubtitles", r.language.uppercased()]
        if r.hashMatch { bits.append("matches this file") }
        if r.hearingImpaired { bits.append("SDH") }
        if r.machineTranslated { bits.append("machine translated") }
        if r.downloads > 0 { bits.append("\(r.downloads) downloads") }
        return bits.joined(separator: " · ")
    }

    private var languages: [String] {
        let s = AppSettings.shared
        var langs = [Decide.iso639_1(s.subtitleLanguage), Decide.iso639_1(c.plan.audio?.languageCode), "en"].compactMap { $0 }
        langs = langs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return langs
    }

    /// OpenSubtitles directly (with the file hash, like Infuse) and the server's own subtitle search.
    private func search() async {
        searching = true; message = nil; results = []
        defer { searching = false }
        let item = c.item
        var out: [Online.SubtitleResult] = []
        if let part = c.plan.part {
            do {
                out += try await Online.shared.searchSubtitles(item: item, show: c.showItem, languages: languages,
                                                               fileURL: PlexClient.shared.directPlayURL(part), fileSize: part.size)
            } catch { message = error.localizedDescription }
        }
        for lang in languages.prefix(2) {
            let code = Decide.norm(lang) ?? lang
            for s in await PlexClient.shared.searchServerSubtitles(item, language: code) {
                out.append(Online.SubtitleResult(source: "plex", fileId: s.key ?? UUID().uuidString, language: lang,
                                                 title: s.string("providerTitle").map { "\($0): \(s.displayTitle)" } ?? s.displayTitle,
                                                 plexStream: s))
            }
        }
        results = out
        if out.isEmpty && message == nil { message = "Nothing found." }
    }

    private func pick(_ r: Online.SubtitleResult) async {
        do {
            if let stream = r.plexStream {
                try await PlexClient.shared.saveServerSubtitle(c.item, stream)
                message = "Saved to the server. It appears in the list after reopening the title."
                return
            }
            let url = try await Online.shared.download(r)
            c.useOnlineSubtitle(url, title: r.title)
            results = []
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Subtitle delay. On Apple TV a click starts adjusting and ◀ ▶ change it in 0.1 s steps (everything else in the
/// panel is disabled meanwhile so focus stays put); a click or Menu finishes. Elsewhere: − and + buttons.
private struct DelayRow: View {
    @ObservedObject var c: PlayerController
    private var value: String { String(format: "%+.1f s", c.subtitleDelay) }

    var body: some View {
        #if os(tvOS)
        Button { c.adjustingDelay.toggle() } label: {
            HStack(spacing: 14.s) {
                Image(systemName: "timer")
                Text("Delay").font(.callout)
                Spacer()
                if c.adjustingDelay {
                    Text("◀  \(value)  ▶").font(.callout.bold()).monospacedDigit()
                } else {
                    Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 520.s)
        }
        .onMoveCommand { d in
            guard c.adjustingDelay else { return }
            switch d {
            case .left: c.adjustSubtitleDelay(-0.1)
            case .right: c.adjustSubtitleDelay(0.1)
            default: break
            }
        }
        #else
        HStack(spacing: 12.s) {
            Text("Delay \(value)").font(.caption).monospacedDigit()
            Spacer()
            Button("−0.1") { c.adjustSubtitleDelay(-0.1) }
            Button("+0.1") { c.adjustSubtitleDelay(0.1) }
            Button("Reset") { c.adjustSubtitleDelay(-c.subtitleDelay) }
        }
        .buttonStyle(.bordered)
        .frame(width: 520.s)
        #endif
    }
}

private struct PictureTab: View {
    @ObservedObject var c: PlayerController
    var body: some View {
        VStack(alignment: .leading, spacing: 12.s) {
            ForEach(PlayerController.Fit.allCases) { f in
                OptionButton(title: f.label, selected: c.fit == f) { c.fit = f }
            }
            Text(Platform.isTV ? "Frame rate and dynamic range follow the video when \"Match Content\" is on in the Apple TV's Video and Audio settings."
                               : "HDR and Dolby Vision show on HDR screens; the system handles the brightness.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 900.s, alignment: .leading)
        }
    }
}
