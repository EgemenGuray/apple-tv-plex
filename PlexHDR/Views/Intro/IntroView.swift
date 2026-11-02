import AVFoundation
import SwiftUI

/// Startup intro: in the dark the light in the corner of the L ignites, the Lumen chime strikes, the light spills
/// along the L, then the camera zooms straight into the middle of the L (no pan) and the app opens behind it.
/// 3.6 s; any button or click skips it.
/// The same timeline is used on Shield (IntroScreen.kt) and Tizen (app/js/intro.js); the chime file is shared.
enum IntroTimeline {
    static let duration = 3.6
    static let strike = 0.95
    static let zoomStart = 2.4
    static let zoomEnd = 3.2
    static let fadeStart = 3.05

    struct State {
        var ignite: Double   // corner light 0...1
        var flare: Double    // bloom at the chime strike
        var radius: Double   // light gradient radius in logo units (64 = the app icon)
        var glow: Double
        var zoom: Double     // 1 -> 14x, straight into the middle of the L
        var fade: Double     // intro layer opacity
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let v = clamp((x - a) / (b - a)); return v * v * (3 - 2 * v)
    }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    private static func easeIn(_ x: Double) -> Double { pow(clamp(x), 3) }

    static func state(at t: Double) -> State {
        let ignite = smooth(0.35, strike, t)
        let flare = t < 0.5 ? 0 : exp(-pow((t - strike) / 0.22, 2))
        let spill = easeOut((t - 0.55) / 1.35)
        let breathe = t > 1.9 && t < zoomStart ? 0.06 * sin((t - 1.9) / 0.5 * .pi) : 0
        let z = clamp((t - zoomStart) / (zoomEnd - zoomStart))
        return State(
            ignite: ignite,
            flare: flare,
            radius: 3 + 61 * spill,
            glow: min(1, ignite * (0.85 + 0.55 * flare) + breathe),
            zoom: exp(log(14) * easeIn(z)),
            fade: 1 - smooth(fadeStart, duration, t))
    }
}

enum IntroRenderer {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: max(0, min(1, a)))
    }

    /// The mark's path in its 100x100 logo space (same as lumen-mark.svg).
    static let mark: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 33, y: 16))
        p.addLine(to: CGPoint(x: 33, y: 62))
        p.addQuadCurve(to: CGPoint(x: 50, y: 79), control: CGPoint(x: 33, y: 79))
        p.addLine(to: CGPoint(x: 86, y: 79))
        return p
    }()

    static func draw(_ base: GraphicsContext, size: CGSize, t: Double) {
        let s = IntroTimeline.state(at: t)
        var ctx = base
        ctx.opacity = s.fade
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        let w = size.width, h = size.height
        let unit = min(w, h) * 0.0058
        let light = CGPoint(x: 33, y: 79)       // light source: the corner of the L
        let middle = CGPoint(x: 59.5, y: 47.5)  // middle of the L (centre of its bounds), kept at the screen centre
        var m = ctx
        m.translateBy(x: w / 2, y: h / 2)
        m.scaleBy(x: unit * s.zoom, y: unit * s.zoom)
        m.translateBy(x: -middle.x, y: -middle.y)

        if s.glow > 0.001 {
            let g = Gradient(stops: [
                .init(color: rgb(255, 207, 138, 0.85 * s.glow), location: 0),
                .init(color: rgb(255, 154, 77, 0.3 * s.glow), location: 0.4),
                .init(color: rgb(255, 122, 61, 0), location: 1)])
            m.fill(Path(ellipseIn: CGRect(x: -4, y: 35, width: 80, height: 80)),
                   with: .radialGradient(g, center: CGPoint(x: 36, y: 75), startRadius: 0, endRadius: 28 + 10 * s.flare))
        }
        if s.ignite > 0.001 {
            let a = s.ignite
            let g = Gradient(stops: [
                .init(color: rgb(255, 255, 255, a), location: 0),
                .init(color: rgb(255, 230, 184, a), location: 0.22),
                .init(color: rgb(255, 154, 77, a), location: 0.55),
                .init(color: rgb(255, 90, 61, 0), location: 1)])
            m.stroke(mark, with: .radialGradient(g, center: light, startRadius: 0, endRadius: s.radius),
                     style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
        }
        if s.flare > 0.01 {
            var f = m
            f.blendMode = .plusLighter
            let bloom = Gradient(stops: [
                .init(color: rgb(255, 240, 215, 0.55 * s.flare), location: 0),
                .init(color: rgb(255, 190, 120, 0.25 * s.flare), location: 0.15),
                .init(color: rgb(255, 120, 60, 0), location: 1)])
            f.fill(Path(CGRect(x: light.x - 70, y: light.y - 70, width: 140, height: 140)),
                   with: .radialGradient(bloom, center: light, startRadius: 0, endRadius: 70))
            // A thin horizontal streak, like light leaking past the edge of a curtain.
            let streak = Gradient(stops: [
                .init(color: rgb(255, 170, 100, 0), location: 0),
                .init(color: rgb(255, 236, 205, 0.5 * s.flare), location: 0.5),
                .init(color: rgb(255, 170, 100, 0), location: 1)])
            f.fill(Path(CGRect(x: light.x - 90, y: light.y - 0.9, width: 180, height: 1.8)),
                   with: .linearGradient(streak, startPoint: CGPoint(x: light.x - 90, y: 0), endPoint: CGPoint(x: light.x + 90, y: 0)))
        }
    }
}

/// Keeps the chime alive after the intro view goes away, so its tail rings out under the app.
@MainActor
enum IntroChime {
    private static var player: AVAudioPlayer?

    static func prepare() {
        guard player == nil, let url = Bundle.main.url(forResource: "lumen_chime", withExtension: "m4a") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }
    static func play() { prepare(); player?.currentTime = 0; player?.play() }
    /// Skipped: fade the chime out quickly instead of cutting it.
    static func fadeOut() { player?.setVolume(0, fadeDuration: 0.4) }
}

struct IntroView: View {
    var playSound: Bool
    var onFinish: () -> Void
    @State private var start = Date()
    @State private var done = false

    var body: some View {
        Button(action: finish) {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                Canvas { ctx, size in IntroRenderer.draw(ctx, size: size, t: t) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .buttonStyle(IntroButtonStyle())
        .ignoresSafeArea()
        .accessibilityLabel("Lumen")
        .accessibilityHint("Skips the intro")
        #if os(tvOS)
        .onExitCommand(perform: finish)
        .onPlayPauseCommand(perform: finish)
        #endif
        .onAppear {
            start = Date()
            if playSound { IntroChime.play() }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(IntroTimeline.duration * 1_000_000_000))
            if !done { done = true; onFinish() }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        if playSound { IntroChime.fadeOut() }
        onFinish()
    }
}

/// No focus lift or press highlight: the whole screen is the button.
private struct IntroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
