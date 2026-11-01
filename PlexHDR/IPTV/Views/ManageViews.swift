import SwiftUI

// MARK: - Playlists

/// Sources, guide, parental PIN, hidden groups.
struct PlaylistsView: View {
    @ObservedObject private var store = IPTVStore.shared
    @State private var editing: IPTVPlaylist?
    @State private var adding = false
    @State private var settingPIN = false
    @State private var newPIN = ""
    @State private var askPIN = false
    @State private var deleting: IPTVPlaylist?

    var body: some View {
        List {
            Section {
                Button { adding = true } label: { Label("Add Playlist", systemImage: "plus.circle.fill") }
                ForEach(store.playlists) { p in playlistRow(p) }
            } header: { Text("Playlists") }

            Section {
                HStack {
                    Text(store.guideUpdated.map { "Updated \(IPTVFormat.day($0)) \(IPTVFormat.time($0))" } ?? "Not loaded")
                    Spacer()
                    if store.guideLoading { ProgressView() }
                }
                Button("Refresh Guide") { Task { await store.refreshGuide() } }
                Button("Refresh Everything") { Task { await store.refreshAll() } }
            } header: { Text("TV Guide") }

            Section {
                if store.pin.isEmpty {
                    Button("Set a PIN") { newPIN = ""; settingPIN = true }
                } else {
                    Button(store.unlocked ? "Lock Locked Groups Again" : "Unlock Locked Groups") {
                        if store.unlocked { store.lock() } else { askPIN = true }
                    }
                    Button("Change PIN") { newPIN = ""; settingPIN = true }
                    Button("Remove PIN", role: .destructive) { store.setPIN(""); for g in store.groups(.live, includeHidden: true) + store.groups(.movie, includeHidden: true) + store.groups(.series, includeHidden: true) where store.isLocked(g) { store.setLocked(g, false) } }
                }
                Text("Long-press a group to lock it with the PIN or hide it.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Parental Control") }

            let hidden = (store.groups(.live, includeHidden: true) + store.groups(.movie, includeHidden: true) + store.groups(.series, includeHidden: true)).filter(store.isHidden)
            if !hidden.isEmpty {
                Section {
                    ForEach(hidden) { g in
                        Button { store.setHidden(g, false) } label: {
                            HStack { Text(g.name); Spacer(); Text(g.kind == .live ? "Live TV" : g.kind == .movie ? "Movies" : "Series").foregroundStyle(.secondary); Image(systemName: "eye") }
                        }
                    }
                } header: { Text("Hidden Groups (select to show again)") }
            }

            Section {
                Button("Clear Recently Watched") { store.clearRecents() }
                if !store.reminders.isEmpty {
                    ForEach(store.reminders) { r in
                        HStack { Text(r.title); Spacer(); Text("\(r.channelName) · \(IPTVFormat.day(r.start)) \(IPTVFormat.time(r.start))").foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("Library") }
        }
        .sheet(isPresented: $adding) { PlaylistEditor(playlist: nil) }
        .sheet(item: $editing) { PlaylistEditor(playlist: $0) }
        .alert("PIN", isPresented: $settingPIN) {
            SecureField("4 digits or more", text: $newPIN)
            Button("Save") { if newPIN.count >= 4 { store.setPIN(newPIN) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Locked groups ask for this PIN.") }
        .alert("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let d = deleting { store.delete(d.id) } }
            Button("Cancel", role: .cancel) {}
        }
        .pinPrompt($askPIN)
    }

    private func playlistRow(_ p: IPTVPlaylist) -> some View {
        let c = store.contents[p.id]
        return Button { editing = p } label: {
            HStack(alignment: .top, spacing: 20.s) {
                Circle().fill(p.color).frame(width: 18.s, height: 18.s).padding(.top, 10.s)
                VStack(alignment: .leading, spacing: 6.s) {
                    HStack {
                        Text(p.name).font(.headline)
                        Text(p.kind.label).font(.caption).foregroundStyle(.secondary)
                        if !p.enabled { Text("Off").font(.caption.bold()).foregroundStyle(.orange) }
                    }
                    if let c {
                        Text("\(c.channels.count) channels · \(c.movies.count) movies · \(c.series.count) series").font(.caption).foregroundStyle(.secondary)
                    }
                    if let a = c?.account {
                        Text([a.status, a.expires.map { "expires \(IPTVFormat.dayFormatter.string(from: $0))" },
                              a.maxConnections.map { "\(a.activeConnections ?? 0)/\($0) connections" }, a.trial == true ? "trial" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let r = p.lastRefresh { Text("Refreshed \(IPTVFormat.day(r)) \(IPTVFormat.time(r))").font(.caption2).foregroundStyle(.secondary) }
                    if let e = store.errors[p.id] { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if store.loading.contains(p.id) { ProgressView() }
            }
        }
        .contextMenu {
            Button("Refresh") { Task { await store.refresh(p.id) } }
            Button(p.enabled ? "Turn Off" : "Turn On") { store.setEnabled(p.id, !p.enabled) }
            Button("Edit") { editing = p }
            Button("Delete", role: .destructive) { deleting = p }
        }
    }
}

struct PlaylistEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = IPTVStore.shared
    @State private var p: IPTVPlaylist
    private let isNew: Bool

    init(playlist: IPTVPlaylist?) {
        isNew = playlist == nil
        _p = State(initialValue: playlist ?? IPTVPlaylist(name: "", kind: .xtream, url: ""))
    }

    private var valid: Bool {
        !p.url.trimmingCharacters(in: .whitespaces).isEmpty && (p.kind == .m3u || (!p.username.isEmpty && !p.password.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $p.kind) {
                        ForEach(IPTVPlaylist.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $p.name)
                }
                Section {
                    if p.kind == .m3u {
                        TextField("Playlist address (http://…/playlist.m3u)", text: $p.url).noAutocaps()
                    } else {
                        TextField("Server (http://host:port)", text: $p.url).noAutocaps()
                        TextField("Username", text: $p.username).noAutocaps()
                        SecureField("Password", text: $p.password)
                    }
                } header: { Text(p.kind == .m3u ? "M3U / M3U8" : "Xtream Codes") }
                Section {
                    TextField("Guide address (XMLTV, optional)", text: $p.epgURL).noAutocaps()
                    TextField("User agent (optional)", text: $p.userAgent).noAutocaps()
                } header: { Text("Optional") } footer: {
                    Text("Lumen uses the guide the playlist names. Add another XMLTV address here if it has none; separate several with commas.")
                }
                if !isNew {
                    Section {
                        Toggle("Enabled", isOn: $p.enabled)
                        Button("Delete Playlist", role: .destructive) { store.delete(p.id); dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Playlist" : "Edit Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            p.name = URL(string: p.kind == .xtream ? XtreamClient.normalize(p.url) : p.url)?.host ?? "Playlist"
                        }
                        store.save(p)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }
}

extension View {
    @ViewBuilder func noAutocaps() -> some View {
        #if os(macOS)
        autocorrectionDisabled()
        #else
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }
}

// MARK: - Downloads and recordings

struct JobsView: View {
    let kind: IPTVRecorder.Job.Kind
    @ObservedObject private var recorder = IPTVRecorder.shared

    private var jobs: [IPTVRecorder.Job] { kind == .download ? recorder.downloads : recorder.recordings }

    var body: some View {
        let list = jobs
        Group {
            if list.isEmpty {
                VStack(spacing: 16.s) {
                    Image(systemName: kind == .download ? "arrow.down.circle" : "record.circle").font(.system(size: 60.s))
                    Text(kind == .download ? "No downloads" : "No recordings").font(.headline)
                    Text(kind == .download ? "Download movies and episodes from their pages, or past programmes from the TV Guide."
                                           : "Record a channel from its menu or the player, or schedule a programme in the TV Guide.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1000.s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(list) { j in row(j) }
                    } footer: {
                        Text(storageNote)
                    }
                }
            }
        }
    }

    private var storageNote: String {
        let size = ByteCountFormatter.string(fromByteCount: recorder.usedBytes, countStyle: .file)
        #if os(tvOS)
        return "\(size) used. Apple TV keeps these in its cache, which tvOS may clear when space runs low. Recordings run while Lumen is open."
        #else
        return "\(size) used, in \(IPTVRecorder.directory.path). Recordings run while Lumen is open."
        #endif
    }

    private func row(_ j: IPTVRecorder.Job) -> some View {
        Button { if j.state == .done { IPTVPlayerPresenter.shared.file(j) } } label: {
            HStack(spacing: 20.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8.s).fill(.white.opacity(0.06))
                    RemoteImage(url: j.poster.flatMap { URL(string: $0) }, contentMode: .fit, placeholder: .clear)
                }
                .frame(width: 120.s, height: 80.s)
                VStack(alignment: .leading, spacing: 6.s) {
                    Text(j.title).font(.headline).lineLimit(1)
                    if let s = j.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 12.s) {
                        Text(stateText(j)).font(.caption.bold()).foregroundStyle(stateColor(j))
                        if j.received > 0 { Text(ByteCountFormatter.string(fromByteCount: j.received, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if j.state == .running, let p = j.progress { ProgressBar(value: p).frame(maxWidth: 600.s) }
                    if let e = j.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                }
                Spacer()
                if j.state == .done { Image(systemName: "play.circle.fill").font(.title2) }
            }
        }
        .contextMenu {
            if j.state == .done { Button("Play") { IPTVPlayerPresenter.shared.file(j) } }
            if j.state == .running || j.state == .scheduled { Button(j.state == .running ? "Stop" : "Cancel") { recorder.stop(j.id) } }
            if j.state == .failed || j.state == .cancelled { Button("Try Again") { recorder.retry(j.id) } }
            Button("Delete", role: .destructive) { recorder.delete(j.id) }
        }
        #if os(iOS)
        .swipeActions { Button("Delete", role: .destructive) { recorder.delete(j.id) } }
        #endif
    }

    private func stateText(_ j: IPTVRecorder.Job) -> String {
        switch j.state {
        case .scheduled: return "Scheduled · \(IPTVFormat.day(j.start)) \(IPTVFormat.time(j.start))"
        case .running: return j.kind == .recording ? "Recording" : "Downloading"
        case .done: return "Ready"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func stateColor(_ j: IPTVRecorder.Job) -> Color {
        switch j.state {
        case .running: return .red
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
