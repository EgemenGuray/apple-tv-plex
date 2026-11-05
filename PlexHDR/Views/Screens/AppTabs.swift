import SwiftUI

/// Lumen is two apps in one: Plex and Live TV (IPTV). Each has its own tabs, and the first item of the tab bar
/// (or a switch above the tabs on iPhone, iPad and Mac) moves between them. The last one used is remembered.
enum AppMode: String {
    case plex, live
    var title: String { self == .plex ? "Plex" : "Live TV" }
}

struct AppTabs: View {
    /// False in IPTV-only mode: choosing Plex then goes to the Plex sign-in.
    let plexSignedIn: Bool
    @AppStorage("app.mode") private var modeRaw = AppMode.plex.rawValue

    private var mode: AppMode { plexSignedIn ? AppMode(rawValue: modeRaw) ?? .plex : .live }

    var body: some View {
        Group {
            switch mode {
            case .plex: PlexTabs(choose: choose)
            case .live: LiveTabs(choose: choose)
            }
        }
        #if !os(tvOS)
        .safeAreaInset(edge: .top, spacing: 0) { ModeSwitchBar(mode: mode, choose: choose) }
        #endif
    }

    private func choose(_ m: AppMode) {
        modeRaw = m.rawValue
        if m == .plex && !plexSignedIn { IPTVStore.shared.iptvOnly = false }
    }
}

// MARK: - Plex

struct PlexTabs: View {
    let choose: (AppMode) -> Void
    @EnvironmentObject private var plex: PlexClient
    private let commands = AppCommands.shared
    @State private var sections: [PlexSection] = []
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            #if os(tvOS)
            ModeSwitchPage(current: .plex) { m in if m == .plex { tab = "home" } else { choose(m) } }
                .tabItem { Text(ModeSwitchPage.tabTitle) }.tag("mode")
            #endif
            PlexStack { HomeView() }
                .tabItem { tabTitle("Home", "house") }.tag("home")
            if Platform.isPhone {
                // A phone has room for five tabs; the libraries share one.
                PlexStack { LibrariesList(sections: sections.filter(\.isVideo)) }
                    .tabItem { tabTitle("Libraries", "rectangle.stack") }.tag("libraries")
            } else {
                ForEach(sections.filter(\.isVideo)) { s in
                    PlexStack { LibraryView(section: s) }
                        .tabItem { tabTitle(s.title, s.type == "show" ? "tv" : "film") }.tag("lib-\(s.id)")
                }
            }
            PlexStack { SearchView() }
                .tabItem { tabIcon("Search", "magnifyingglass") }.tag("search")
            NavigationStack { SettingsView() }
                .tabItem { tabIcon("Settings", "gearshape") }.tag("settings")
        }
        .task(id: plex.server?.machineId) {
            sections = (try? await plex.sections()) ?? []
        }
        .onReceive(commands.$request) { r in
            guard let r else { return }
            tab = r == .search ? "search" : "settings"
            commands.request = nil
        }
    }
}

/// iPhone: the video libraries in one tab.
struct LibrariesList: View {
    let sections: [PlexSection]
    var body: some View {
        List(sections) { s in
            NavigationLink { LibraryView(section: s).navigationTitle(s.title) } label: {
                Label(s.title, systemImage: s.type == "show" ? "tv" : "film")
            }
        }
        .overlay { if sections.isEmpty { ProgressView() } }
        .navigationTitle("Libraries")
    }
}

// MARK: - Live TV

struct LiveTabs: View {
    let choose: (AppMode) -> Void
    private let commands = AppCommands.shared
    @AppStorage("iptv.tab") private var tab = IPTVSection.home.rawValue

    /// A phone shows the first four sections as tabs and the rest under More.
    private var tabs: [IPTVSection] { Platform.isPhone ? [.home, .live, .guide, .search] : IPTVSection.tabs }
    private var more: [IPTVSection] { IPTVSection.tabs.filter { !tabs.contains($0) } }

    var body: some View {
        TabView(selection: $tab) {
            #if os(tvOS)
            ModeSwitchPage(current: .live) { m in if m == .live { tab = IPTVSection.home.rawValue } else { choose(m) } }
                .tabItem { Text(ModeSwitchPage.tabTitle) }.tag("mode")
            #endif
            // Search and Settings are icons on Apple TV, as in Plex mode.
            ForEach(Array(tabs.prefix(while: { $0 != .search }))) { s in
                section(s).tabItem { tabTitle(s.title, s.symbol) }.tag(s.rawValue)
            }
            if tabs.contains(.search) {
                section(.search).tabItem { tabIcon("Search", "magnifyingglass") }.tag(IPTVSection.search.rawValue)
            }
            ForEach(tabs.drop(while: { $0 != .search }).filter { $0 != .search && $0 != .settings }) { s in
                section(s).tabItem { tabTitle(s.title, s.symbol) }.tag(s.rawValue)
            }
            if tabs.contains(.settings) {
                section(.settings).tabItem { tabIcon("Settings", "gearshape") }.tag(IPTVSection.settings.rawValue)
            }
            if Platform.isPhone {
                NavigationStack {
                    List(more) { s in
                        NavigationLink { IPTVSectionView(section: s).navigationTitle(s.title) } label: { Label(s.title, systemImage: s.symbol) }
                    }
                    .navigationTitle("More")
                    .iptvRoutes()
                }
                .tabItem { tabTitle("More", "ellipsis") }.tag("more")
            }
        }
        .onAppear {
            // The switch page, or a section that is under More on a phone.
            if !(tabs.map(\.rawValue) + ["more"]).contains(tab) { tab = IPTVSection.home.rawValue }
        }
        .onReceive(commands.$request) { r in
            guard let r else { return }
            tab = r == .search ? IPTVSection.search.rawValue : (Platform.isPhone ? "more" : IPTVSection.settings.rawValue)
            commands.request = nil
        }
    }

    private func section(_ s: IPTVSection) -> some View {
        NavigationStack { IPTVSectionView(section: s).iptvRoutes() }
    }
}

/// A tab's title: text on Apple TV (like the TV app), icon and title elsewhere.
@ViewBuilder func tabTitle(_ title: String, _ symbol: String) -> some View {
    #if os(tvOS)
    Text(title)
    #else
    Label(title, systemImage: symbol)
    #endif
}

/// Search and Settings: just the icon on Apple TV.
@ViewBuilder func tabIcon(_ title: String, _ symbol: String) -> some View {
    #if os(tvOS)
    Image(systemName: symbol)
    #else
    Label(title, systemImage: symbol)
    #endif
}

// MARK: - The switch

#if os(tvOS)
/// The first tab on Apple TV. The focus engine selects a tab as soon as it gets focus, so the tab itself can't
/// toggle; it opens this page with the two modes, the other one focused, so one click switches.
struct ModeSwitchPage: View {
    static let tabTitle = "Plex | Live TV"
    let current: AppMode
    let choose: (AppMode) -> Void
    @Namespace private var scope

    var body: some View {
        HStack(spacing: 80) {
            card(.plex, symbol: "play.rectangle.on.rectangle", detail: "Your Plex movies and shows")
            card(.live, symbol: "tv", detail: "Channels, TV guide, IPTV movies and series")
        }
        .focusScope(scope)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private func card(_ m: AppMode, symbol: String, detail: String) -> some View {
        Button { choose(m) } label: {
            VStack(spacing: 24) {
                Image(systemName: symbol).font(.system(size: 110))
                Text(m.title).font(.title2.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(m == current ? "Current" : "Switch to \(m.title)")
                    .font(.caption.bold())
                    .foregroundStyle(m == current ? .green : .secondary)
            }
            .padding(40)
            .frame(width: 560, height: 440)
        }
        .buttonStyle(.card)
        .prefersDefaultFocus(m != current, in: scope)
    }
}
#else
/// Plex | Live TV above the tabs on iPhone, iPad and Mac.
struct ModeSwitchBar: View {
    let mode: AppMode
    let choose: (AppMode) -> Void

    var body: some View {
        Picker("Mode", selection: Binding(get: { mode }, set: { choose($0) })) {
            Text(AppMode.plex.title).tag(AppMode.plex)
            Text(AppMode.live.title).tag(AppMode.live)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
#endif
