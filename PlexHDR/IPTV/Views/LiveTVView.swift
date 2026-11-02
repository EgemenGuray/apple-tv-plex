import SwiftUI

/// Groups on the left, channels with what's on in the middle, and a muted preview of the focused channel.
struct LiveTVView: View {
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var presenter = IPTVPlayerPresenter.shared
    @StateObject private var preview = PreviewPlayer()
    @AppStorage("iptv.liveGroup") private var groupKey = "all"
    @State private var focused: IPTVChannel?
    @State private var askPIN = false
    @State private var pendingGroup: String?
    @State private var tagFilter: Set<IPTVTag> = []
    @ObservedObject private var sq = IPTVSectionSearch.shared

    private var groups: [IPTVGroup] { store.groups(.live) }

    private var lineup: [IPTVChannel] {
        var list: [IPTVChannel]
        if sq.active(.live) {
            list = store.channels.filter { sq.hits(.live, $0.name, $0.group, store.nowNext($0).0?.title) }
            if !tagFilter.isEmpty { list = list.filter { tagFilter.isSubset(of: store.tags($0)) } }
            return list
        }
        switch groupKey {
        case "all": list = store.channels
        case "favorites": list = store.favoriteChannels
        case "recents": list = store.recentChannels
        default:
            if let g = groups.first(where: { $0.id == groupKey }) { list = store.channels(in: g) } else { list = store.channels }
        }
        if !tagFilter.isEmpty { list = list.filter { tagFilter.isSubset(of: store.tags($0)) } }
        return list
    }

    private var groupTitle: String {
        if sq.active(.live) { return "Search results" }
        switch groupKey {
        case "all": return "All Channels"
        case "favorites": return "Favorites"
        case "recents": return "Recently Watched"
        default: return groups.first { $0.id == groupKey }?.name ?? "All Channels"
        }
    }

    var body: some View {
        let list = lineup
        Group {
            if Platform.isPhone {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Menu {
                            groupMenuItems
                        } label: {
                            Label(groupTitle, systemImage: "line.3.horizontal.decrease.circle").font(.headline)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    SectionSearchField(section: .live, prompt: "channels and what's on").padding(.horizontal)
                    tagBar
                    ChannelList(channels: list, focused: $focused)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    groupList.frame(width: 440.s)
                    VStack(alignment: .leading, spacing: 12.s) {
                        HStack {
                            Text(groupTitle).font(.title3.bold())
                            Text("\(list.count)").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 30.s)
                        SectionSearchField(section: .live, prompt: "channels and what's on").padding(.horizontal, 30.s)
                        tagBar
                        ChannelList(channels: list, focused: $focused)
                    }
                    .frame(maxWidth: .infinity)
                    if Platform.isTV || Platform.isMac { previewPane.frame(width: 640.s) }
                }
            }
        }
        .pinPrompt($askPIN) { if let g = pendingGroup { groupKey = g } }
        .onChange(of: presenter.request?.id) { _, id in if id != nil { preview.stop() } }
        .onDisappear { preview.stop() }
        .task(id: focused?.id) {
            guard let ch = focused, presenter.request == nil else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled, presenter.request == nil { preview.load(ch) }
        }
    }

    @ViewBuilder private var groupMenuItems: some View {
        Button("All Channels") { groupKey = "all" }
        Button("Favorites") { groupKey = "favorites" }
        Button("Recently Watched") { groupKey = "recents" }
        ForEach(groups) { g in Button(g.name) { pick(g) } }
    }

    private func pick(_ g: IPTVGroup) {
        if store.isLocked(g) && !store.unlocked { pendingGroup = g.id; askPIN = true } else { groupKey = g.id }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4.s) {
                groupButton("All Channels", key: "all", icon: "square.grid.2x2")
                groupButton("Favorites", key: "favorites", icon: "star.fill")
                groupButton("Recently Watched", key: "recents", icon: "clock")
                Divider().padding(.vertical, 10.s)
                ForEach(groups) { g in
                    Button { pick(g) } label: {
                        HStack(spacing: 12.s) {
                            if store.playlists.count > 1 { SourceDot(playlistID: g.playlistID) }
                            Text(g.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if store.isLocked(g) { Image(systemName: store.unlocked ? "lock.open" : "lock.fill").font(.caption) }
                        }
                        .padding(.horizontal, 20.s).padding(.vertical, 12.s)
                        .background(RoundedRectangle(cornerRadius: 10.s).fill(groupKey == g.id ? .white.opacity(0.15) : .clear))
                    }
                    .buttonStyle(PanelRowStyle())
                    .contextMenu { GroupMenu(group: g) }
                }
            }
            .padding(.horizontal, 30.s).padding(.bottom, 60.s)
        }
        .tvFocusSection()
    }

    private func groupButton(_ title: String, key: String, icon: String) -> some View {
        Button { groupKey = key } label: {
            Label(title, systemImage: icon).lineLimit(1)
                .padding(.horizontal, 20.s).padding(.vertical, 12.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10.s).fill(groupKey == key ? .white.opacity(0.15) : .clear))
        }
        .buttonStyle(PanelRowStyle())
    }

    /// Filter by picture and sound quality.
    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12.s) {
                ForEach(IPTVTag.allCases) { t in
                    Button {
                        if tagFilter.contains(t) { tagFilter.remove(t) } else { tagFilter.insert(t) }
                    } label: {
                        Text(t.rawValue).font(.caption.bold()).padding(.horizontal, 18.s).padding(.vertical, 6.s)
                    }
                    .buttonStyle(PillStyle(selected: tagFilter.contains(t)))
                }
            }
            .padding(.horizontal, 30.s).padding(.vertical, 6.s)
        }
        .tvFocusSection()
    }

    @ViewBuilder private var previewPane: some View {
        VStack(alignment: .leading, spacing: 20.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 16.s).fill(.black)
                if let l = preview.layer, preview.channelID == focused?.id {
                    PreviewLayerView(layer: l).clipShape(RoundedRectangle(cornerRadius: 16.s))
                    if !preview.ready { ProgressView() }
                } else if let ch = focused {
                    ChannelLogo(channel: ch, size: 120.s)
                } else {
                    Image(systemName: "tv").font(.system(size: 60.s)).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            if let ch = focused {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let (now, next) = store.nowNext(ch, at: ctx.date)
                    VStack(alignment: .leading, spacing: 10.s) {
                        Text(ch.name).font(.headline).lineLimit(1)
                        HStack(spacing: 8.s) { ForEach(store.tags(ch).sorted { $0.rawValue < $1.rawValue }) { QualityBadge(tag: $0) } }
                        if let now {
                            Text(now.title).font(.callout.bold()).lineLimit(2)
                            HStack { Text(now.timeRange).font(.caption).foregroundStyle(.secondary); ProgressBar(value: now.progress(at: ctx.date)) }
                            if let d = now.desc { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(5) }
                        }
                        if let next { Text("Next  \(IPTVFormat.time(next.start))  \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 30.s)
    }
}

/// Channel rows; picking one plays it with this list as the lineup for ▲▼.
struct ChannelList: View {
    let channels: [IPTVChannel]
    @Binding var focused: IPTVChannel?
    @ObservedObject private var store = IPTVStore.shared
    @FocusState private var focusID: String?

    var body: some View {
        if channels.isEmpty {
            Text(store.loading.isEmpty ? "No channels here." : "Loading channels…").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                ScrollView {
                    LazyVStack(spacing: 4.s) {
                        ForEach(channels) { ch in
                            ChannelRow(channel: ch, now: ctx.date) { IPTVPlayerPresenter.shared.live(ch, lineup: channels) }
                                .focused($focusID, equals: ch.id)
                                #if os(macOS)
                                .onHover { if $0 { focused = ch } }
                                #endif
                        }
                    }
                    .padding(.horizontal, 30.s).padding(.bottom, 60.s)
                }
            }
            .tvFocusSection()
            .onChange(of: focusID) { _, id in if let id { focused = channels.first { $0.id == id } } }
        }
    }
}

struct ChannelRow: View {
    let channel: IPTVChannel
    let now: Date
    let play: () -> Void
    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var recorder = IPTVRecorder.shared
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let (cur, next) = store.nowNext(channel, at: now)
        Button(action: play) {
            HStack(spacing: 20.s) {
                Text(channel.number.map(String.init) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70.s, alignment: .trailing)
                ChannelLogo(channel: channel, size: 70.s)
                VStack(alignment: .leading, spacing: 6.s) {
                    HStack(spacing: 10.s) {
                        if store.playlists.count > 1 { SourceDot(playlistID: channel.playlistID) }
                        Text(channel.name).font(.callout.bold()).lineLimit(1)
                        ForEach(store.tags(channel).sorted { $0.rawValue < $1.rawValue }) { QualityBadge(tag: $0) }
                        if store.isFavorite(channel.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        if channel.hasCatchup { Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
                        if recorder.isRecording(channel: channel) != nil { Image(systemName: "record.circle").font(.caption).foregroundStyle(.red) }
                    }
                    if let cur {
                        HStack(spacing: 12.s) {
                            Text(cur.title).font(.caption).lineLimit(1)
                            ProgressBar(value: cur.progress(at: now)).frame(width: 140.s)
                        }
                        if let next, !Platform.isPhone { Text("\(IPTVFormat.time(next.start))  \(next.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16.s).padding(.vertical, 10.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
        .contextMenu {
            Button { store.toggleFavorite(channel.id) } label: {
                Label(store.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star")
            }
            Button { newName = channel.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if let job = recorder.isRecording(channel: channel) {
                Button { recorder.stop(job.id) } label: { Label("Stop Recording", systemImage: "stop.circle") }
            } else {
                if let cur { Button { recorder.record(channel, programme: cur) } label: { Label("Record “\(cur.title)”", systemImage: "record.circle") } }
                Button { recorder.record(channel, minutes: 60) } label: { Label("Record 1 Hour", systemImage: "record.circle") }
            }
        }
        .alert("Rename Channel", isPresented: $renaming) {
            TextField(store.originalName(channel), text: $newName)
            Button("Save") { store.rename(channel, to: newName) }
            Button("Reset") { store.rename(channel, to: "") }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Hide or lock a group.
struct GroupMenu: View {
    let group: IPTVGroup
    @ObservedObject private var store = IPTVStore.shared
    var body: some View {
        Button { store.setHidden(group, true) } label: { Label("Hide Group", systemImage: "eye.slash") }
        if store.pin.isEmpty {
            Text("Set a PIN in Playlists to lock groups")
        } else {
            Button { store.setLocked(group, !store.isLocked(group)) } label: {
                Label(store.isLocked(group) ? "Unlock Group" : "Lock Group with PIN", systemImage: "lock")
            }
        }
    }
}
