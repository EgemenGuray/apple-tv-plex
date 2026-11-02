import SwiftUI

/// The TV guide: channels down the side, programmes across a time window that moves back through the catch-up
/// days and forward through the guide. A programme opens actions: watch live, watch from the start (catch-up),
/// record, download, remind.
struct GuideView: View {
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var recorder = IPTVRecorder.shared
    @AppStorage("iptv.guideGroup") private var groupKey = "all"
    @State private var windowStart = GuideView.defaultStart()
    @State private var picked: Picked?
    @State private var askPIN = false
    @State private var pendingGroup: String?
    @ObservedObject private var sq = IPTVSectionSearch.shared

    struct Picked: Identifiable { let channel: IPTVChannel; let programme: IPTVProgramme; var id: String { programme.id + channel.id } }

    private let hours: Double = Platform.isPhone ? 2 : 2.5
    private var hourWidth: CGFloat { Platform.isPhone ? 260 : 620.s }
    private var channelWidth: CGFloat { Platform.isPhone ? 110 : 340.s }
    private var windowEnd: Date { windowStart.addingTimeInterval(hours * 3600) }

    static func defaultStart() -> Date {
        let now = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (now / 1800).rounded(.down) * 1800 - 1800)
    }

    private var groups: [IPTVGroup] { store.groups(.live) }
    private var channels: [IPTVChannel] {
        if sq.active(.guide) {
            // Channels whose name matches, or that show a matching programme within a day of the guide's start.
            let end = windowStart.addingTimeInterval(86400)
            return store.channels.filter { ch in
                sq.hits(.guide, ch.name) || store.programmes(ch, from: windowStart, to: end).contains { sq.hits(.guide, $0.title, $0.episode, $0.category) }
            }
        }
        switch groupKey {
        case "all": return store.channels
        case "favorites": return store.favoriteChannels
        default: return groups.first { $0.id == groupKey }.map { store.channels(in: $0) } ?? store.channels
        }
    }
    private var groupTitle: String {
        groupKey == "all" ? "All Channels" : groupKey == "favorites" ? "Favorites" : groups.first { $0.id == groupKey }?.name ?? "All Channels"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10.s) {
            header
            SectionSearchField(section: .guide, prompt: "channels and programmes")
            if store.hasGuide, sq.active(.guide), channels.isEmpty {
                SectionNoMatch(section: .guide)
                Spacer()
            } else if !store.hasGuide {
                VStack(spacing: 20.s) {
                    if store.guideLoading { ProgressView(); Text("Loading the TV guide…") }
                    else {
                        Text("No TV guide yet.").font(.headline)
                        Text("Lumen uses the guide your playlist names. You can add a guide (XMLTV) address to the playlist in Playlists.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Load Guide") { Task { await store.refreshGuide() } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeRuler
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 6.s) {
                            ForEach(channels) { ch in row(ch, now: ctx.date) }
                        }
                        .padding(.bottom, 60.s)
                    }
                    .overlay(alignment: .topLeading) { nowLine(ctx.date) }
                }
                .id(store.guideVersion)
            }
        }
        .padding(.horizontal, Platform.isPhone ? 8 : 40.s)
        .pinPrompt($askPIN) { if let g = pendingGroup { groupKey = g } }
        .confirmationDialog(picked?.programme.title ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { p in
            actions(p)
        } message: { p in
            Text([p.channel.name, "\(IPTVFormat.day(p.programme.start)) \(p.programme.timeRange)", p.programme.episode, p.programme.desc]
                .compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private var header: some View {
        HStack(spacing: 20.s) {
            Menu {
                Button("All Channels") { groupKey = "all" }
                Button("Favorites") { groupKey = "favorites" }
                ForEach(groups) { g in
                    Button(g.name) {
                        if store.isLocked(g) && !store.unlocked { pendingGroup = g.id; askPIN = true } else { groupKey = g.id }
                    }
                }
            } label: {
                Label(groupTitle, systemImage: "line.3.horizontal.decrease.circle").lineLimit(1)
            }
            Spacer()
            Text(IPTVFormat.day(windowStart)).font(.headline)
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button("Now") { windowStart = GuideView.defaultStart() }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            if store.guideLoading { ProgressView() }
        }
        .tvFocusSection()
    }

    /// Back as far as the longest catch-up (at least a day), forward four days.
    private func shift(_ dir: Int) {
        let maxDays = Double(max(1, store.channels.compactMap { $0.catchup?.days }.max() ?? 1))
        let next = windowStart.addingTimeInterval(Double(dir) * hours * 3600 * 0.8)
        let earliest = Date().addingTimeInterval(-maxDays * 86400)
        let latest = Date().addingTimeInterval(4 * 86400)
        windowStart = min(max(next, earliest), latest)
    }

    private var timeRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: channelWidth)
            ForEach(0..<Int(hours * 2), id: \.self) { i in
                Text(IPTVFormat.time(windowStart.addingTimeInterval(Double(i) * 1800)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: hourWidth / 2, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func nowLine(_ now: Date) -> some View {
        if now > windowStart && now < windowEnd {
            Rectangle().fill(.red).frame(width: 2)
                .offset(x: channelWidth + CGFloat(now.timeIntervalSince(windowStart) / 3600) * hourWidth)
                .allowsHitTesting(false)
        }
    }

    private func row(_ ch: IPTVChannel, now: Date) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10.s) {
                ChannelLogo(channel: ch, size: Platform.isPhone ? 26 : 50.s)
                if !Platform.isPhone { Text(ch.name).font(.caption.bold()).lineLimit(2) }
            }
            .frame(width: channelWidth, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(cells(ch)) { cell in
                    if let p = cell.programme {
                        Button { picked = Picked(channel: ch, programme: p) } label: {
                            programmeCell(ch, p, now: now).frame(width: max(2, cell.width - 4))
                        }
                        .buttonStyle(GuideCellStyle(airing: p.isAiring(at: now)))
                        .frame(width: cell.width)
                    } else {
                        Color.clear.frame(width: cell.width)
                    }
                }
            }
            .frame(width: CGFloat(hours) * hourWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: Platform.isPhone ? 54 : 96.s)
        .tvFocusSection()
    }

    private func programmeCell(_ ch: IPTVChannel, _ p: IPTVProgramme, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4.s) {
            HStack(spacing: 6.s) {
                if recorder.isRecording(ch, p) { Image(systemName: "record.circle").foregroundStyle(.red) }
                if store.hasReminder(ch, p) { Image(systemName: "bell.fill").foregroundStyle(.yellow) }
                if store.canCatchUp(ch, p) && p.end < now { Image(systemName: "clock.arrow.circlepath") }
                Text(p.title).lineLimit(1)
            }
            .font(.caption.bold())
            Text(IPTVFormat.time(p.start)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    struct Cell: Identifiable { let id: String; let width: CGFloat; let programme: IPTVProgramme? }

    /// Programme blocks and gaps across the window.
    private func cells(_ ch: IPTVChannel) -> [Cell] {
        var out: [Cell] = []
        var cursor = windowStart
        let perSecond = hourWidth / 3600
        for p in store.programmes(ch, from: windowStart, to: windowEnd) {
            let s = max(p.start, windowStart)
            let e = min(p.end, windowEnd)
            if s > cursor { out.append(Cell(id: "gap\(cursor.timeIntervalSince1970)", width: CGFloat(s.timeIntervalSince(cursor)) * perSecond, programme: nil)) }
            if e > s { out.append(Cell(id: p.id, width: CGFloat(e.timeIntervalSince(max(s, cursor))) * perSecond, programme: p)) }
            cursor = max(cursor, e)
        }
        if out.isEmpty {
            out.append(Cell(id: "none", width: CGFloat(hours) * hourWidth, programme: nil))
        }
        return out
    }

    @ViewBuilder private func actions(_ pk: Picked) -> some View {
        let ch = pk.channel
        let p = pk.programme
        let now = Date()
        if p.isAiring(at: now) {
            Button("Watch Live") { IPTVPlayerPresenter.shared.live(ch, lineup: channels) }
            if store.canCatchUp(ch, p) { Button("Watch from the Start") { IPTVPlayerPresenter.shared.catchup(ch, p) } }
        } else if p.end <= now {
            if store.canCatchUp(ch, p) {
                Button("Watch (Catch-up)") { IPTVPlayerPresenter.shared.catchup(ch, p) }
                Button("Download") { recorder.download(catchup: p, on: ch) }
            }
        } else {
            Button(store.hasReminder(ch, p) ? "Cancel Reminder" : "Remind Me") { store.toggleReminder(ch, p) }
        }
        if p.end > now {
            Button(recorder.isRecording(ch, p) ? "Already Recording" : "Record") { if !recorder.isRecording(ch, p) { recorder.record(ch, programme: p) } }
        }
        Button(store.isFavorite(ch.id) ? "Remove Channel from Favorites" : "Add Channel to Favorites") { store.toggleFavorite(ch.id) }
        Button("Cancel", role: .cancel) {}
    }
}

struct GuideCellStyle: ButtonStyle {
    var airing: Bool
    func makeBody(configuration: Configuration) -> some View { CellBody(configuration: configuration, airing: airing) }
    private struct CellBody: View {
        let configuration: ButtonStyleConfiguration
        let airing: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? .black : .white)
                .background(RoundedRectangle(cornerRadius: 8.s).fill(focused ? .white : airing ? .white.opacity(0.18) : .white.opacity(0.07)))
                .scaleEffect(focused ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
                .contentShape(Rectangle())
        }
    }
}
