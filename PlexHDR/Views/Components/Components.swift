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
    var width: CGFloat = 260.s
    @State private var tmdbPoster: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10.s) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: PlexClient.shared.imageURL(item.posterPath ?? tmdbPoster, width: Int(width * 1.5), height: Int(width * 2.25)))
                    .frame(width: width, height: width * 1.5)
                    .clipped()
                if !item.isWatched, item.type == "show", let leaves = item.leafCount, let seen = item.viewedLeafCount, leaves - seen > 0 {
                    Text("\(leaves - seen)")
                        .font(.caption2.bold()).padding(.horizontal, 10.s).padding(.vertical, 4.s)
                        .background(.ultraThinMaterial, in: Capsule()).padding(10.s)
                } else if item.isWatched {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.4)).padding(10.s)
                }
            }
            .overlay(alignment: .bottom) { ProgressLine(progress: item.progress) }
            .clipShape(RoundedRectangle(cornerRadius: 12.s, style: .continuous))
        }
        .frame(width: width)
        .task(id: item.id) {
            if item.posterPath == nil { tmdbPoster = await Online.shared.artwork(item)?.poster }
        }
    }
}

struct WideCard: View {
    let item: PlexItem
    var width: CGFloat = 480.s
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8.s) {
            RemoteImage(url: PlexClient.shared.imageURL(item.type == "episode" ? (item.thumb ?? item.backdropPath) : item.backdropPath,
                                                        width: Int(width * 1.5), height: Int(width * 1.5 * 9 / 16)))
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) { ProgressLine(progress: item.progress) }
                .clipShape(RoundedRectangle(cornerRadius: 12.s, style: .continuous))
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
            .frame(height: 6.s).padding(.horizontal, 12.s).padding(.bottom, 10.s)
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
        VStack(alignment: .leading, spacing: 16.s) {
            Text(title).font(.title3.bold()).padding(.leading, 80.s)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40.s) {
                    ForEach(items) { item in
                        ItemLink(item: item, onFocus: onFocus) {
                            if wide { WideCard(item: item) } else { PosterCard(item: item) }
                        }
                    }
                }
                .padding(.horizontal, 80.s).padding(.vertical, 30.s)
            }
            .scrollClipDisabled()
        }
        .tvFocusSection()
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
            .padding(.horizontal, 10.s).padding(.vertical, 3.s)
            .overlay(RoundedRectangle(cornerRadius: 5.s).stroke(.white.opacity(0.7), lineWidth: 1.5.s))
            .foregroundStyle(.white.opacity(0.9))
    }
}

/// Ratings with each site's logo, in this order: IMDb, Letterboxd, Tomatometer, RT Audience, Metacritic (users),
/// Metascore (critics). The Rotten Tomatoes logos change with the score, as on their site.
struct RatingsRow: View {
    let ratings: Online.Ratings
    var body: some View {
        HStack(spacing: 34.s) {
            if let v = ratings.imdb { item(IMDbLogo(), v) }
            if let v = ratings.letterboxd { item(LetterboxdLogo(), v) }
            if let v = ratings.rtCritic { item(TomatometerLogo(score: percent(v)), v) }
            if let v = ratings.rtAudience { item(PopcornLogo(score: percent(v)), v) }
            if let v = ratings.metaUser { item(ScoreBadge(score: (Double(v) ?? 0) * 10, text: v, circle: true, caption: "User"), nil) }
            if let v = ratings.metaCritic { item(ScoreBadge(score: Double(v) ?? 0, text: v, circle: false, caption: "Metascore"), nil) }
        }
    }
    private func percent(_ v: String) -> Int { Int(v.filter(\.isNumber)) ?? 0 }
    private func item<L: View>(_ logo: L, _ value: String?) -> some View {
        HStack(spacing: 10.s) {
            logo
            if let value { Text(value).font(.callout.weight(.semibold)).monospacedDigit() }
        }
    }
}

struct IMDbLogo: View {
    var body: some View {
        Text("IMDb").font(.system(size: 22.s, weight: .black)).foregroundStyle(.black)
            .padding(.horizontal, 8.s).padding(.vertical, 3.s)
            .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 5.s))
    }
}

struct LetterboxdLogo: View {
    var body: some View {
        HStack(spacing: -7.s) {
            Circle().fill(Color(red: 1, green: 0.5, blue: 0))
            Circle().fill(Color(red: 0, green: 0.88, blue: 0.33)).blendMode(.screen)
            Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96)).blendMode(.screen)
        }
        .frame(width: 54.s, height: 22.s)
    }
}

/// Fresh tomato (60%+), Certified Fresh (75%+, gold ring) or a green rotten splat.
struct TomatometerLogo: View {
    let score: Int
    var body: some View {
        ZStack {
            if score >= 60 {
                Circle().fill(Color(red: 0.98, green: 0.2, blue: 0.08))
                    .overlay(alignment: .top) {
                        Star(points: 5, inner: 0.4).fill(Color(red: 0, green: 0.6, blue: 0.2)).frame(width: 14.s, height: 9.s).offset(y: -2.s)
                    }
                    .padding(score >= 75 ? 4.s : 0)
                if score >= 75 { Circle().stroke(Color(red: 1, green: 0.8, blue: 0.1), lineWidth: 3.s) }
            } else {
                Star(points: 9, inner: 0.62).fill(Color(red: 0.04, green: 0.75, blue: 0.29)).rotationEffect(.degrees(12))
            }
        }
        .frame(width: 30.s, height: 30.s)
    }
}

/// Upright red popcorn bucket (60%+) or a tipped-over green one.
struct PopcornLogo: View {
    let score: Int
    var body: some View {
        let fresh = score >= 60
        ZStack(alignment: .top) {
            HStack(spacing: -4.s) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(red: 1, green: 0.93, blue: 0.7)).frame(width: 12.s, height: 12.s) }
            }
            .offset(y: -3.s)
            Bucket().fill(fresh ? Color(red: 0.98, green: 0.2, blue: 0.08) : Color(red: 0.04, green: 0.75, blue: 0.29))
                .overlay(Bucket().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2.s, dash: [3, 4])))
                .frame(width: 24.s, height: 22.s).offset(y: 6.s)
        }
        .frame(width: 30.s, height: 30.s)
        .rotationEffect(.degrees(fresh ? 0 : -100))
    }
    private struct Bucket: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + r.width * 0.18, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// Metacritic-style score: green 61+, yellow 40–60, red below 40. Square for the Metascore, round for users.
struct ScoreBadge: View {
    let score: Double
    let text: String
    let circle: Bool
    let caption: String
    var body: some View {
        let color = score >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2) : score >= 40 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 0.94, green: 0.15, blue: 0.15)
        HStack(spacing: 8.s) {
            Text(text).font(.system(size: 20.s, weight: .heavy)).foregroundStyle(score >= 40 && score < 61 ? .black : .white)
                .frame(width: 44.s, height: 36.s)
                .background(color, in: circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6.s)))
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

struct Star: Shape {
    let points: Int
    let inner: CGFloat
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), outer = min(r.width, r.height) / 2
        var p = Path()
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outer : outer * inner
            let a = Double(i) * .pi / Double(points) - .pi / 2
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * radius, y: c.y + CGFloat(sin(a)) * radius)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Title logo when Plex (or TMDB) has one, otherwise the title in large type.
struct TitleLogo: View {
    let item: PlexItem
    var maxWidth: CGFloat = 700.s
    var maxHeight: CGFloat = 220.s
    @State private var tmdbLogo: String?

    var body: some View {
        Group {
            if let logo = item.clearLogo ?? tmdbLogo, let url = logo.hasPrefix("http") ? URL(string: logo) : PlexClient.shared.imageURL(logo, width: 1200, height: 400) {
                RemoteImage(url: url, contentMode: .fit, placeholder: .clear)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
            } else {
                Text(item.displayTitle).font(.system(size: 76.s, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.5)
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
        VStack(spacing: 30.s) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60.s))
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 1000.s)
            if let retry { Button("Try Again", action: retry) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
