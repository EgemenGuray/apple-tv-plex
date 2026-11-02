import SwiftUI

/// Each IPTV section's own search text. A section's search looks through the whole section, not just the open group.
@MainActor
final class IPTVSectionSearch: ObservableObject {
    static let shared = IPTVSectionSearch()
    @Published var text: [IPTVSection: String] = [:]

    func query(_ s: IPTVSection) -> String { (text[s] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    func active(_ s: IPTVSection) -> Bool { !query(s).isEmpty }

    /// True when the section isn't being searched, or any of the values contains its search text.
    func hits(_ s: IPTVSection, _ values: String?...) -> Bool {
        let q = query(s)
        if q.isEmpty { return true }
        return values.contains { $0?.lowercased().contains(q) == true }
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
                Button { sq.text[section] = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func field(_ text: Binding<String>) -> some View {
        #if os(tvOS)
        TextField("Search \(prompt)", text: text).autocorrectionDisabled()
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
