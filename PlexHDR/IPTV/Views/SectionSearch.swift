import SwiftUI

/// Each IPTV section's own search text. A section's search looks through the whole section, not just the open group.
/// What is typed is applied after a short pause, so long lists aren't filtered again on every key.
@MainActor
final class IPTVSectionSearch: ObservableObject {
    static let shared = IPTVSectionSearch()
    /// What is in the field.
    @Published var text: [IPTVSection: String] = [:] {
        didSet { scheduleApply() }
    }
    /// What the lists filter by: `text` once typing pauses.
    @Published private(set) var applied: [IPTVSection: String] = [:]
    private var applyTask: Task<Void, Never>?
    private var foldCache: [String: String] = [:]

    private func scheduleApply() {
        // Clearing applies at once; typing waits for a pause.
        for (k, v) in text where v.trimmingCharacters(in: .whitespaces).isEmpty && applied[k] != nil { applied[k] = nil }
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            let next = self.text.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            if self.applied != next { self.applied = next }
        }
    }

    /// Clears a section's search at once.
    func clear(_ s: IPTVSection) {
        text[s] = ""
        applied[s] = nil
    }

    func query(_ s: IPTVSection) -> String { (applied[s] ?? "").trimmingCharacters(in: .whitespaces).searchFolded }
    func active(_ s: IPTVSection) -> Bool { !query(s).isEmpty }

    /// The words of a section's search, folded.
    func words(_ s: IPTVSection) -> [String] {
        let raw = applied[s] ?? ""
        if let c = wordsCache[s], c.0 == raw { return c.1 }
        let w = query(s).split(whereSeparator: \.isWhitespace).map(String.init)
        wordsCache[s] = (raw, w)
        return w
    }
    private var wordsCache: [IPTVSection: (String, [String])] = [:]

    /// True when the section isn't being searched, or every word of its search is found in one of the values.
    func hits(_ s: IPTVSection, _ values: String?...) -> Bool {
        let w = words(s)
        if w.isEmpty { return true }
        let folded = values.compactMap { $0.map(fold) }
        return w.allSatisfy { word in folded.contains { $0.contains(word) } }
    }

    /// Folds a value, remembering the result: channel names are folded again on every key otherwise.
    func fold(_ v: String) -> String {
        if let f = foldCache[v] { return f }
        if foldCache.count > 300_000 { foldCache.removeAll(keepingCapacity: true) }
        let f = v.searchFolded
        foldCache[v] = f
        return f
    }
}

extension String {
    /// For matching: lower case without accents, with Turkish İ/I/ı all as i, and superscript and small-capital
    /// letters (ᴿᴬᵂ, ⁴ᴷ, ʜᴅ) as plain ones.
    var searchFolded: String {
        var s = precomposedStringWithCompatibilityMapping
        if s.unicodeScalars.contains(where: { ($0.value >= 0x1D00 && $0.value <= 0x1DBF) || $0.value == 0x131 || $0.value == 0x130 || String.smallCaps[$0] != nil }) {
            var out = String.UnicodeScalarView()
            for u in s.unicodeScalars {
                switch u.value {
                case 0x130, 0x131: out.append("i")
                default:
                    if let r = String.smallCaps[u] { out.append(contentsOf: r.unicodeScalars) } else { out.append(u) }
                }
            }
            s = String(out)
        }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static let smallCaps: [Unicode.Scalar: String] = {
        let pairs: [(UInt32, String)] = [
            (0x1D00, "a"), (0x0299, "b"), (0x1D04, "c"), (0x1D05, "d"), (0x1D07, "e"), (0xA730, "f"), (0x0262, "g"),
            (0x029C, "h"), (0x026A, "i"), (0x1D0A, "j"), (0x1D0B, "k"), (0x029F, "l"), (0x1D0D, "m"), (0x0274, "n"),
            (0x1D0F, "o"), (0x1D18, "p"), (0x0280, "r"), (0xA731, "s"), (0x1D1B, "t"), (0x1D1C, "u"), (0x1D20, "v"),
            (0x1D21, "w"), (0x028F, "y"), (0x1D22, "z"), (0x1D2C, "a"), (0x1D2E, "b"), (0x1D30, "d"), (0x1D31, "e"),
            (0x1D33, "g"), (0x1D34, "h"), (0x1D35, "i"), (0x1D36, "j"), (0x1D37, "k"), (0x1D38, "l"), (0x1D39, "m"),
            (0x1D3A, "n"), (0x1D3C, "o"), (0x1D3E, "p"), (0x1D3F, "r"), (0x1D40, "t"), (0x1D41, "u"), (0x1D42, "w"),
            (0x2C7D, "v"), (0x1D3B, "n"),
        ]
        var m: [Unicode.Scalar: String] = [:]
        for (v, r) in pairs { if let u = Unicode.Scalar(v) { m[u] = r } }
        return m
    }()

    /// The letter a name is filed under in an A–Z index: A–Z, or # for anything else.
    var indexLetter: String {
        guard let c = searchFolded.first(where: { !$0.isWhitespace && !"|-:[]()★*.".contains($0) }), let a = c.unicodeScalars.first,
              a.value >= 97 && a.value <= 122 else { return "#" }
        return String(c).uppercased()
    }
}

/// The search field at the top of a section.
struct SectionSearchField: View {
    let section: IPTVSection
    let prompt: String
    @ObservedObject private var sq = IPTVSectionSearch.shared

    var body: some View {
        let text = Binding(get: { sq.text[section] ?? "" }, set: { sq.text[section] = $0 })
        HStack(spacing: 12.s) {
            HStack(spacing: 10.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                field(text)
            }
            .frame(maxWidth: Platform.isPhone ? .infinity : 620.s)
            if !text.wrappedValue.isEmpty {
                Button { sq.clear(section) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func field(_ text: Binding<String>) -> some View {
        #if os(tvOS)
        TextField("Search \(prompt)", text: text).noAutocaps()
        #else
        TextField("Search \(prompt)", text: text).textFieldStyle(.roundedBorder).autocorrectionDisabled()
        #endif
    }
}

/// Shown when a section's search finds nothing.
struct SectionNoMatch: View {
    let section: IPTVSection
    @ObservedObject private var sq = IPTVSectionSearch.shared
    var body: some View {
        Text("Nothing matches “\((sq.text[section] ?? "").trimmingCharacters(in: .whitespaces))”.")
            .foregroundStyle(.secondary).padding(60.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension String {
    /// A short label for a channel without a logo: "Kanal 2 HD" gives K2, "TRT 1" gives TRT 1, "Discovery Science" gives DS.
    var channelInitials: String {
        var n = replacingOccurrences(of: #"^\s*[A-Z]{2,4}\s*[:|\-]\s*"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: #"\b(4K|UHD|FHD|HD|SD|HEVC|H265|50FPS|60FPS|RAW|BACKUP)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        let w = n.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = w.first else { return "" }
        let num = w.count > 1 && w[1].allSatisfy(\.isNumber) ? w[1] : ""
        let out: String
        if first.count <= 4 { out = num.isEmpty ? first : "\(first) \(num)" }
        else if !num.isEmpty { out = String(first.prefix(1)) + num }
        else if w.count > 1 { out = w.prefix(3).map { String($0.prefix(1)) }.joined() }
        else { out = String(first.prefix(5)) }
        return out.uppercased()
    }
}
