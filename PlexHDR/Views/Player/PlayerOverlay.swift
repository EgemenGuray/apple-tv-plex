import SwiftUI

/// Apple TV-style transport overlay: title and badges at the top; at the bottom the timeline with chapter ticks and
/// intro/credits segments, elapsed and remaining time, the chapter name and "Ends at". While scrubbing, a preview
/// thumbnail rides above the scrub head.
struct PlayerOverlay: View {
    @ObservedObject var c: PlayerController

    var body: some View {
        VStack(alignment: .leading) {
            top
            Spacer()
            bottom
        }
        .padding(.horizontal, 90).padding(.vertical, 60)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).frame(height: 300)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 420)
            }
        }
        .ignoresSafeArea()
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 10) {
            if c.item.type == "episode" {
                Text(c.item.grandparentTitle ?? "").font(.title3.bold())
                Text("\(c.item.episodeLabel ?? "") · \(c.item.title)").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(c.item.title).font(.title2.bold())
            }
            HStack(spacing: 10) {
                ForEach(Decide.badges(c.plan), id: \.self) { Badge(text: $0) }
                if c.rate != 1 { Badge(text: "\(c.rate)×") }
            }
        }
    }

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let ch = c.currentChapter { Text(ch.title).font(.caption).foregroundStyle(.secondary) }
            Timeline(c: c).frame(height: 14)
            HStack {
                Text(formatTime(c.scrubTime ?? c.time)).monospacedDigit()
                Spacer()
                Text(endsAt).foregroundStyle(.secondary)
                Spacer()
                Text("-" + formatTime(max(0, c.duration - (c.scrubTime ?? c.time)))).monospacedDigit()
            }
            .font(.caption)
        }
    }

    private var endsAt: String {
        let remaining = max(0, c.duration - c.time) / Double(c.rate)
        let f = DateFormatter(); f.timeStyle = .short
        return "Ends at " + f.string(from: Date().addingTimeInterval(remaining))
    }
}

struct Timeline: View {
    @ObservedObject var c: PlayerController

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let d = max(c.duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 8)
                // Intro and credits segments.
                ForEach(Array(c.item.markers.enumerated()), id: \.offset) { _, m in
                    Rectangle().fill((m.isIntro ? Color.blue : Color.purple).opacity(0.6))
                        .frame(width: max(2, w * (m.end - m.start) / d), height: 8)
                        .offset(x: w * m.start / d)
                }
                Capsule().fill(.white).frame(width: w * min(1, c.time / d), height: 8)
                // Chapter ticks.
                ForEach(Array(c.chapters.dropFirst().enumerated()), id: \.offset) { _, ch in
                    Rectangle().fill(.black.opacity(0.7)).frame(width: 3, height: 8).offset(x: w * ch.start / d)
                }
                if let s = c.scrubTime {
                    let x = w * s / d
                    Rectangle().fill(.white).frame(width: 4, height: 26).offset(x: x - 2)
                    ScrubPreview(c: c, time: s)
                        .offset(x: min(max(0, x - 200), w - 400), y: -170)
                }
            }
            .frame(height: g.size.height)
        }
    }
}

struct ScrubPreview: View {
    @ObservedObject var c: PlayerController
    let time: TimeInterval
    var body: some View {
        VStack(spacing: 8) {
            if let img = c.bif?.image(at: time) {
                Image(uiImage: img).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: 400, height: 225).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 3))
            }
            Text(formatTime(time)).font(.callout.bold()).monospacedDigit()
                .padding(.horizontal, 14).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule())
        }
        .frame(width: 400)
    }
}
