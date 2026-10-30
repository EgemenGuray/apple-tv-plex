import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var plex: PlexClient
    @EnvironmentObject private var settings: AppSettings
    @State private var users: [PlexClient.HomeUser] = []
    @State private var pinFor: PlexClient.HomeUser?
    @State private var error: String?
    @State private var showServers = false

    private let languages: [(String, String)] = [("", "Automatic"), ("eng", "English"), ("tur", "Türkçe"), ("ger", "Deutsch"), ("fre", "Français"),
                                                 ("spa", "Español"), ("ita", "Italiano"), ("jpn", "日本語"), ("kor", "한국어")]

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Server", value: "\(plex.server?.name ?? "") \(plex.server?.relay == true ? "(Relay: slow)" : "")")
                LabeledContent("User", value: plex.user?.title ?? "")
                ForEach(users) { u in
                    Button {
                        if u.protected { pinFor = u } else { Task { await switchTo(u, pin: nil) } }
                    } label: {
                        HStack {
                            Text("Switch to \(u.title)")
                            if u.protected { Image(systemName: "lock.fill") }
                            Spacer()
                            if u.id == plex.user?.uuid { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button("Change Server") { showServers = true }
                Button("Sign Out", role: .destructive) { plex.signOut() }
                if let error { Text(error).foregroundStyle(.red) }
            }

            Section {
                Picker("Audio track", selection: $settings.audioPreference) {
                    ForEach(AppSettings.AudioPreference.allCases) { Text($0.label).tag($0) }
                }
                Picker("Audio language", selection: $settings.audioLanguage) {
                    ForEach(languages.indices, id: \.self) { i in Text(languages[i].1).tag(languages[i].0) }
                }
                Toggle("Apple decoder for Dolby Atmos (MP4)", isOn: $settings.appleDecoderForAtmos)
                Toggle("Dolby Atmos from MKV via server remux (experimental)", isOn: $settings.remuxForAtmos)
                LabeledContent("Current output", value: AudioSetup.routeDescription)
            } header: { Text("Audio") } footer: {
                Text("Every track is decoded on the Apple TV and sent as multichannel PCM (up to 7.1). On AirPods and Beats, tvOS plays 5.1/7.1 as Spatial Audio with head tracking. Dolby Atmos height objects are only kept with Apple's decoder, which needs a DD+ Atmos track in an MP4, or the experimental remux for MKV. For Spatial Audio, turn it on in Control Center on the Apple TV while the AirPods are connected.")
            }

            Section("Subtitles") {
                Picker("Show", selection: $settings.subtitleMode) {
                    ForEach(AppSettings.SubtitleMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: $settings.subtitleLanguage) {
                    ForEach(languages.indices, id: \.self) { i in Text(languages[i].1).tag(languages[i].0) }
                }
                Toggle("Also in the audio language", isOn: $settings.subtitlesInAudioLanguage)
                Picker("Size", selection: $settings.subtitleSize) {
                    ForEach([0.75, 0.9, 1.0, 1.15, 1.3, 1.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                Picker("Colour", selection: $settings.subtitleColor) {
                    ForEach(AppSettings.SubtitleColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Style", selection: $settings.subtitleStyle) {
                    ForEach(AppSettings.SubtitleStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Position", selection: $settings.subtitleBottomMargin) {
                    ForEach([0.02, 0.06, 0.1, 0.15], id: \.self) { Text("\(Int($0 * 100))% from bottom").tag($0) }
                }
            }

            Section("Playback") {
                Toggle("Autoplay next episode", isOn: $settings.autoplayNext)
                Toggle("Skip intros automatically", isOn: $settings.autoSkipIntro)
                Toggle("Skip credits automatically", isOn: $settings.autoSkipCredits)
                Picker("Skip back", selection: $settings.skipBack) { ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) } }
                Picker("Skip forward", selection: $settings.skipForward) { ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }
                Toggle("Match frame rate", isOn: $settings.matchFrameRate)
            }

            Section {
                Toggle("Artwork from TMDB", isOn: $settings.tmdbArtwork)
                Toggle("Show ratings", isOn: $settings.showRatings)
                TextField("TMDB API key or read token", text: $settings.tmdbKey)
                TextField("OMDb API key", text: $settings.omdbKey)
                TextField("OpenSubtitles API key", text: $settings.openSubtitlesKey)
                TextField("OpenSubtitles username", text: $settings.openSubtitlesUser)
                    .onChange(of: settings.openSubtitlesUser) { _, _ in Online.shared.resetLogin() }
                SecureField("OpenSubtitles password", text: $settings.openSubtitlesPassword)
                    .onChange(of: settings.openSubtitlesPassword) { _, _ in Online.shared.resetLogin() }
            } header: { Text("Online services") } footer: {
                Text("All free. TMDB: themoviedb.org → Settings → API. OMDb: omdbapi.com. OpenSubtitles: opensubtitles.com → API consumers. Typing is easier with the Apple TV Remote on your iPhone.")
            }

            Section("Remote") {
                LabeledContent("Click / Play-Pause", value: "Play or pause; presses Skip Intro / Up Next when shown")
                LabeledContent("◀ ▶ (click or swipe)", value: "Back \(settings.skipBack) s / forward \(settings.skipForward) s; while paused: scrub with thumbnails")
                LabeledContent("Swipe down", value: "Info, chapters, audio, subtitles, picture")
                LabeledContent("Swipe up", value: "Show the timeline")
                LabeledContent("Back / Menu", value: "Close the panel, or stop")
            }
        }
        .task { users = (try? await plex.homeUsers()) ?? [] }
        .sheet(item: $pinFor) { u in PinPad(user: u) { pin in Task { await switchTo(u, pin: pin) } } }
        .sheet(isPresented: $showServers) { ServerPickerView() }
    }

    private func switchTo(_ u: PlexClient.HomeUser, pin: String?) async {
        error = nil
        do { try await plex.switchUser(u, pin: pin); pinFor = nil } catch { self.error = error.localizedDescription }
    }
}

struct PinPad: View {
    let user: PlexClient.HomeUser
    let submit: (String) -> Void
    @State private var pin = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 40) {
            Text("PIN for \(user.title)").font(.title2.bold())
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < pin.count ? .white : .white.opacity(0.2)).frame(width: 30, height: 30)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(140), spacing: 30), count: 3), spacing: 30) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓"], id: \.self) { k in
                    Button {
                        switch k {
                        case "⌫": if !pin.isEmpty { pin.removeLast() }
                        case "✓": submit(pin); dismiss()
                        default:
                            pin.append(k)
                            if pin.count == 4 { submit(pin); dismiss() }
                        }
                    } label: { Text(k).font(.title).frame(width: 100, height: 60) }
                }
            }
            .frame(width: 540)
        }
        .padding(60)
    }
}
