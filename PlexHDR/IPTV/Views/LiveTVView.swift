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
    /// The A–Z strip beside the groups (Apple TV: opened with ◀; elsewhere always shown).
    @State private var letterStrip = false
    /// The group the strip was opened from, to go back to with ▶ or Menu.
    @State private var stripFrom: String?
    @State private var scrollTarget: String?
    @State private var showGroups = false
    @FocusState private var groupFocus: String?
    @FocusState private var letterFocus: String?

    private static let letters = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    /// Every group, favourites first, then A–Z.
    private var groups: [IPTVGroup] { store.sortedGroups(.live) }

    /// The groups the search matches, or all of them.
    private var shownGroups: [IPTVGroup] {
        let all = groups
        return sq.active(.live) ? all.filter { sq.hits(.live, $0.name) } : all
    }

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
            if let g = store.groups(.live).first(where: { $0.id == groupKey }) { list = store.channels(in: g) } else { list = store.channels }
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
        default: return store.groups(.live).first { $0.id == groupKey }?.name ?? "All Channels"
        }
    }

    var body: some View {
        let list = lineup
        Group {
            if Platform.isPhone {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button { showGroups = true } label: {
                            Label(groupTitle, systemImage: "line.3.horizontal.decrease.circle").font(.headline).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    SectionSearchField(section: .live, prompt: "groups, channels and what's on").padding(.horizontal)
                    tagBar
                    ChannelList(channels: list, focused: $focused)
                }
                .sheet(isPresented: $showGroups) {
                    NavigationStack {
                        VStack(spacing: 10) {
                            SectionSearchField(section: .live, prompt: "groups").padding(.horizontal)
                            groupList
                        }
                        .navigationTitle("Groups")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGroups = false } } }
                    }
                    .preferredColorScheme(.dark)
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
                        SectionSearchField(section: .live, prompt: "groups, channels and what's on").padding(.horizontal, 30.s)
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

    /// Opens a group. Picking one ends a search, so the whole group is shown.
    private func pick(_ g: IPTVGroup) {
        sq.clear(.live)
        showGroups = false
        if store.isLocked(g) && !store.unlocked { pendingGroup = g.id; askPIN = true } else { groupKey = g.id }
    }

    private func pick(key: String) {
        sq.clear(.live)
        showGroups = false
        groupKey = key
    }

    private var groupList: some View {
        let list = shownGroups
        return HStack(alignment: .top, spacing: 0) {
            if letterStrip || !Platform.isTV { letterIndex(list) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4.s) {
                        groupButton("All Channels", key: "all", icon: "square.grid.2x2", first: list.first)
                        groupButton("Favorites", key: "favorites", icon: "star.fill", first: list.first)
                        groupButton("Recently Watched", key: "recents", icon: "clock", first: list.first)
                        Divider().padding(.vertical, 10.s)
                        if list.isEmpty, sq.active(.live) {
                            Text("No groups match.").foregroundStyle(.secondary).padding(.horizontal, 20.s)
                        }
                        ForEach(list) { g in groupRow(g).id(g.id) }
                    }
                    .padding(.horizontal, Platform.isTV ? 30.s : 16).padding(.bottom, 60.s)
                }
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    scrollTarget = nil
                }
            }
            .tvFocusSection()
        }
    }

    private func groupRow(_ g: IPTVGroup) -> some View {
        Button { pick(g) } label: {
            HStack(spacing: 12.s) {
                if store.playlists.count > 1 { SourceDot(playlistID: g.playlistID) }
                if store.isFavoriteGroup(g) { Text("★").foregroundStyle(.yellow) }
                Text(g.name).lineLimit(1)
                Spacer(minLength: 0)
                if store.isLocked(g) { Image(systemName: store.unlocked ? "lock.open" : "lock.fill").font(.caption) }
            }
            .padding(.horizontal, 20.s).padding(.vertical, 12.s)
            .background(RoundedRectangle(cornerRadius: 10.s).fill(groupKey == g.id ? .white.opacity(0.15) : .clear))
        }
        .buttonStyle(PanelRowStyle())
        .focused($groupFocus, equals: g.id)
        .contextMenu { GroupMenu(group: g) { refocus(g.id) } }
        #if os(tvOS)
        .onMoveCommand { if $0 == .left { openStrip(from: g) } }
        #endif
    }

    private func groupButton(_ title: String, key: String, icon: String, first: IPTVGroup?) -> some View {
        Button { pick(key: key) } label: {
            Label(title, systemImage: icon).lineLimit(1)
                .padding(.horizontal, 20.s).padding(.vertical, 12.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10.s).fill(groupKey == key && !sq.active(.live) ? .white.opacity(0.15) : .clear))
        }
        .buttonStyle(PanelRowStyle())
        .focused($groupFocus, equals: key)
        #if os(tvOS)
        .onMoveCommand { if $0 == .left { openStrip(from: nil, key: key) } }
        #endif
    }

    /// Keeps focus on a group after the list changed around it (a move or a favourite).
    private func refocus(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            scrollTarget = id
            try? await Task.sleep(nanoseconds: 150_000_000)
            groupFocus = id
        }
    }

    // MARK: - A–Z

    private func letter(_ g: IPTVGroup) -> String { store.groupSortKey(g.name).indexLetter }

    private func openStrip(from g: IPTVGroup?, key: String? = nil) {
        stripFrom = g?.id ?? key
        let start = g.map(letter) ?? shownGroups.first(where: { !store.isFavoriteGroup($0) }).map(letter) ?? "A"
        withAnimation(.easeOut(duration: 0.15)) { letterStrip = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            letterFocus = start
        }
    }

    private func closeStrip() {
        guard Platform.isTV, letterStrip else { return }
        let back = stripFrom
        withAnimation(.easeOut(duration: 0.15)) { letterStrip = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            groupFocus = back
        }
    }

    /// Goes to the first group (after the favourites) starting with the letter, or the next letter that has one.
    private func jump(to l: String, in list: [IPTVGroup]) {
        let rest = list.filter { !store.isFavoriteGroup($0) }
        let order = Self.letters
        let li = order.firstIndex(of: l) ?? 0
        let target = rest.first { letter($0) == l }
            ?? rest.first { (order.firstIndex(of: letter($0)) ?? 0) > li }
            ?? rest.last
        guard let target else { return }
        if Platform.isTV {
            withAnimation(.easeOut(duration: 0.15)) { letterStrip = false }
        }
        scrollTarget = target.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            groupFocus = target.id
        }
    }

    private func letterIndex(_ list: [IPTVGroup]) -> some View {
        let present = Set(list.filter { !store.isFavoriteGroup($0) }.map(letter))
        return ScrollView(showsIndicators: false) {
            VStack(spacing: Platform.isTV ? 4.s : 0) {
                ForEach(Self.letters, id: \.self) { l in
                    Button { jump(to: l, in: list) } label: {
                        Text(l).font(Platform.isTV ? .callout.bold() : .caption2.bold())
                            .frame(width: Platform.isTV ? 64.s : 22, height: Platform.isTV ? 46.s : 17)
                            .opacity(present.contains(l) ? 1 : 0.35)
                    }
                    .buttonStyle(PanelRowStyle())
                    .focused($letterFocus, equals: l)
                    #if os(tvOS)
                    .onMoveCommand { if $0 == .right { closeStrip() } }
                    #endif
                }
            }
            .padding(.vertical, Platform.isTV ? 10.s : 4)
        }
        .frame(width: Platform.isTV ? 84.s : 26)
        .background(Platform.isTV ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12.s))
        .tvFocusSection()
        #if os(tvOS)
        .onExitCommand { closeStrip() }
        #endif
        .transition(.move(edge: .leading).combined(with: .opacity))
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

/// Favourite, move, lock or hide a group. Hide is last, so it isn't picked by accident.
struct GroupMenu: View {
    let group: IPTVGroup
    /// Called after the group moved in the list, to keep focus on it.
    var moved: () -> Void = {}
    @ObservedObject private var store = IPTVStore.shared
    var body: some View {
        if store.isFavoriteGroup(group) {
            Button { store.toggleFavoriteGroup(group); moved() } label: { Label("Remove from Favorite Groups", systemImage: "star.slash") }
            if store.canMoveFavoriteGroup(group, .up) {
                Button { store.moveFavoriteGroup(group, .up); moved() } label: { Label("Move Up", systemImage: "arrow.up") }
            }
            if store.canMoveFavoriteGroup(group, .down) {
                Button { store.moveFavoriteGroup(group, .down); moved() } label: { Label("Move Down", systemImage: "arrow.down") }
            }
            if store.canMoveFavoriteGroup(group, .top) {
                Button { store.moveFavoriteGroup(group, .top); moved() } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
            }
        } else {
            Button { store.toggleFavoriteGroup(group); moved() } label: { Label("Add to Favorite Groups", systemImage: "star") }
        }
        if store.pin.isEmpty {
            Text("Set a PIN in Playlists to lock groups")
        } else {
            Button { store.setLocked(group, !store.isLocked(group)) } label: {
                Label(store.isLocked(group) ? "Unlock Group" : "Lock Group with PIN", systemImage: "lock")
            }
        }
        Button(role: .destructive) { store.setHidden(group, true) } label: { Label("Hide Group", systemImage: "eye.slash") }
    }
}
