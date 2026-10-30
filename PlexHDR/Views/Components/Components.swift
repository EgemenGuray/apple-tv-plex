import SwiftUI

// MARK: - Image loading

/// Memory + disk cached image loading. AsyncImage has no memory cache, which makes rows flicker while scrolling.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, UIImage>()
    private var tasks: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 512 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    init() { memory.totalCostLimit = 200 << 20 }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let i = cached(url) { return i }
        if let t = tasks[url] { return await t.value }
        let t = Task<UIImage?, Never> { [session] in
            guard let r = try? await session.data(from: url), let img = UIImage(data: r.0) else { return nil }
            return await Task.detached { img.preparingForDisplay() ?? img }.value
        }
        tasks[url] = t
        let img = await t.value
        tasks[url] = nil
        if let img { memory.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholder: Color = Color.white.opacity(0.06)
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageCache.shared.cached(url) { image = c; return }
            let img = await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
    }
}

// MARK: - Cards

struct PosterCard: View {
    let item: PlexItem
    var width: CGFloat = 260
    @State private var tmdbPoster: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: PlexClient.shared.imageURL(item.posterPath ?? tmdbPoster, width: Int(width * 1.5), height: Int(width * 2.25)))
                    .frame(width: width, height: width * 1.5)
                    .clipped()
                if !item.isWatched, item.type == "show", let leaves = item.leafCount, let seen = item.viewedLeafCount, leaves - seen > 0 {
                    Text("\(leaves - seen)")
                        .font(.caption2.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule()).padding(10)
                } else if item.isWatched {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.4)).padding(10)
                }
            }
            .overlay(alignment: .bottom) { ProgressLine(progress: item.progress) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: width)
        .task(id: item.id) {
            if item.posterPath == nil { tmdbPoster = await Online.shared.artwork(item)?.poster }
        }
    }
}

struct WideCard: View {
    let item: PlexItem
    var width: CGFloat = 480
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: PlexClient.shared.imageURL(item.type == "episode" ? (item.thumb ?? item.backdropPath) : item.backdropPath,
                                                        width: Int(width * 1.5), height: Int(width * 1.5 * 9 / 16)))
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) { ProgressLine(progress: item.progress) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if showTitle {
                Text(item.displayTitle).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }

    private var subtitle: String {
        if let ep = item.episodeLabel { return "\(ep) · \(item.title)" }
        if let left = item.durationMs.map({ ($0 - item.viewOffsetMs) / 60000 }), item.viewOffsetMs > 0 { return "\(left) min left" }
        return item.year.map(String.init) ?? ""
    }
}

struct ProgressLine: View {
    let progress: Double?
    var body: some View {
        if let p = progress, p > 0.01, p < 0.99 {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.5))
                    Capsule().fill(.white).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6).padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

// MARK: - Rows

struct ItemRow: View {
    let title: String
    let items: [PlexItem]
    var wide = false
    var onFocus: ((PlexItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold()).padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        ItemLink(item: item, onFocus: onFocus) {
                            if wide { WideCard(item: item) } else { PosterCard(item: item) }
                        }
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A card that opens the right screen for its item and reports focus (for the backdrop cross-fade).
struct ItemLink<Label: View>: View {
    let item: PlexItem
    var onFocus: ((PlexItem) -> Void)?
    @ViewBuilder let label: () -> Label
    @FocusState private var focused: Bool

    var body: some View {
        NavigationLink(value: Route.item(item)) { label() }
            .buttonStyle(LiftButtonStyle())
            .focused($focused)
            .onChange(of: focused) { _, f in if f { onFocus?(item) } }
    }
}

/// Apple TV-style focus: the card lifts, grows and casts a shadow.
struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LiftBody(configuration: configuration) }
    private struct LiftBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 1.02 : focused ? 1.1 : 1, anchor: .center)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: focused ? 24 : 0, y: focused ? 16 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: focused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Badges, ratings

struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.7), lineWidth: 1.5))
            .foregroundStyle(.white.opacity(0.9))
    }
}

struct RatingsRow: View {
    let ratings: Online.Ratings
    var body: some View {
        HStack(spacing: 26) {
            if let v = ratings.imdb { chip("IMDb", v, .yellow) }
            if let v = ratings.rtCritic { chip("🍅", v, .red) }
            if let v = ratings.rtAudience { chip("🍿", v, .orange) }
            if let v = ratings.metaCritic { chip("Metascore", v, .green) }
            if let v = ratings.metaUser { chip("MC User", v, .mint) }
            if let v = ratings.letterboxd { chip("Letterboxd", v, .teal) }
        }
    }
    private func chip(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 2)
                .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
            Text(value).font(.callout.weight(.semibold))
        }
    }
}

/// Title logo when Plex (or TMDB) has one, otherwise the title in large type.
struct TitleLogo: View {
    let item: PlexItem
    var maxWidth: CGFloat = 700
    var maxHeight: CGFloat = 220
    @State private var tmdbLogo: String?

    var body: some View {
        Group {
            if let logo = item.clearLogo ?? tmdbLogo, let url = logo.hasPrefix("http") ? URL(string: logo) : PlexClient.shared.imageURL(logo, width: 1200, height: 400) {
                RemoteImage(url: url, contentMode: .fit, placeholder: .clear)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
            } else {
                Text(item.displayTitle).font(.system(size: 76, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.5)
                    .frame(maxWidth: maxWidth * 1.4, alignment: .leading)
            }
        }
        .task(id: item.id) {
            if item.clearLogo == nil { tmdbLogo = await Online.shared.artwork(item)?.logo }
        }
    }
}

/// Full-screen artwork with the Apple TV darkening on the left and bottom.
struct Backdrop: View {
    let item: PlexItem?
    @State private var tmdbBackdrop: String?

    var body: some View {
        ZStack {
            Color.black
            if let item {
                RemoteImage(url: PlexClient.shared.imageURL(item.art ?? item.grandparentArt ?? tmdbBackdrop ?? item.thumb, width: 1920, height: 1080), placeholder: .black)
                    .id(item.id)
                    .transition(.opacity)
                    .task(id: item.id) {
                        if item.art == nil && item.grandparentArt == nil { tmdbBackdrop = await Online.shared.artwork(item)?.backdrop }
                    }
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .center, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: item?.id)
        .ignoresSafeArea()
    }
}

func formatDuration(_ ms: Int?) -> String? {
    guard let ms, ms > 0 else { return nil }
    let m = ms / 60000
    return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite else { return "0:00" }
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct LoadingView: View {
    var body: some View { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 1000)
            if let retry { Button("Try Again", action: retry) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
