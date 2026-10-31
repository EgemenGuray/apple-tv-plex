import SwiftUI

/// Swipe-down panel with tabs: Info, Chapters, Audio, Subtitles, Picture.
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
            .onChange(of: focusedTab) { _, t in if let t { c.panel = t } }

            Group {
                switch c.panel ?? .info {
                case .info: InfoTab(c: c)
                case .chapters: ChaptersTab(c: c)
                case .audio: AudioTab(c: c).scrollsHorizontallyOnSmallScreens()
                case .subtitles: SubtitlesTab(c: c).scrollsHorizontallyOnSmallScreens()
                case .picture: PictureTab(c: c)
                }
            }
            .frame(height: 360.s, alignment: .topLeading)
            .tvFocusSection()
        }
        .padding(.horizontal, 90.s).padding(.top, 40.s).padding(.bottom, 60.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .onAppear { focusedTab = c.panel }
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

private struct AudioTab: View {
    @ObservedObject var c: PlayerController
    var body: some View {
        HStack(alignment: .top, spacing: 60.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12.s) {
                    ForEach(c.plan.part?.audioStreams ?? []) { s in
                        OptionButton(title: s.extendedDisplayTitle, subtitle: detail(s), selected: c.plan.audio?.id == s.id) { c.chooseAudio(s) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12.s) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                    OptionButton(title: "\(r)×", selected: c.rate == r) { c.setRate(r) }
                }
            }
            VStack(alignment: .leading, spacing: 8.s) {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                Text(AudioSetup.routeDescription).font(.caption)
                Text("5.1, 7.1 and Dolby Atmos play as Spatial Audio on AirPods.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 420.s, alignment: .leading)
        }
    }
    private func detail(_ s: PlexStream) -> String {
        var bits: [String] = []
        if Decide.isAtmos(s) && s.codec == "eac3" { bits.append("Atmos objects with Apple's decoder") }
        else if s.channels > 2 { bits.append("\(s.channels) ch PCM · Spatial Audio") }
        if Decide.isLossless(s) { bits.append("lossless") }
        return bits.joined(separator: " · ")
    }
}

private struct SubtitlesTab: View {
    @ObservedObject var c: PlayerController
    @State private var results: [Online.SubtitleResult] = []
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 50.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12.s) {
                    OptionButton(title: "Off", selected: c.plan.subtitle == nil && c.selectedOnlineSubtitle == nil) {
                        Task { await c.select(subtitle: nil) }
                    }
                    ForEach(c.plan.part?.subtitleStreams ?? []) { s in
                        OptionButton(title: s.extendedDisplayTitle, subtitle: s.isExternal ? "External file" : Decide.isImageSub(s) ? "Image subtitle" : nil,
                                     selected: c.plan.subtitle?.id == s.id) { Task { await c.select(subtitle: s) } }
                    }
                    if let name = c.selectedOnlineSubtitle {
                        OptionButton(title: "Downloaded subtitle", subtitle: name, selected: true) {}
                    }
                    Button { Task { await search() } } label: { Label("Search Online…", systemImage: "magnifyingglass") }
                }
            }
            .frame(width: 600.s)
            if searching || !results.isEmpty || message != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12.s) {
                        if searching { ProgressView() }
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        ForEach(results) { r in
                            OptionButton(title: r.title, subtitle: resultDetail(r), selected: false) { Task { await pick(r) } }
                        }
                    }
                }
                .frame(width: 640.s)
            }
            VStack(alignment: .leading, spacing: 12.s) {
                Text("Delay \(String(format: "%+.1f", c.subtitleDelay)) s").font(.caption)
                HStack {
                    Button("−0.1") { c.adjustSubtitleDelay(-0.1) }
                    Button("+0.1") { c.adjustSubtitleDelay(0.1) }
                }
                Button("Reset") { c.adjustSubtitleDelay(-c.subtitleDelay) }
            }
        }
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
