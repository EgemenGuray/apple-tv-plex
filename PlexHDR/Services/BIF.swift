import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Plex trick-play thumbnails: a BIF file is a header, a table of (timestamp, offset) pairs and the JPEGs back to back.
final class BIF {
    private struct Frame { let time: TimeInterval; let range: Range<Int> }
    private let data: Data
    private let frames: [Frame]
    private var cache: (index: Int, image: UIImage)?

    init?(_ data: Data) {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 64, Array(data.prefix(8)) == magic else { return nil }
        func u32(_ at: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            }
        }
        let count = Int(u32(12))
        let mult = Double(u32(16) == 0 ? 1000 : u32(16))
        var out: [Frame] = []
        for n in 0..<count {
            let at = 64 + n * 8
            guard at + 12 <= data.count else { break }
            let t = u32(at)
            if t == 0xFFFF_FFFF { break }
            let start = Int(u32(at + 4)), end = Int(u32(at + 12))
            guard start < end, end <= data.count else { continue }
            out.append(Frame(time: Double(t) * mult / 1000, range: start..<end))
        }
        guard !out.isEmpty else { return nil }
        self.data = data
        frames = out
    }

    /// The thumbnail closest to (at or before) `time` seconds.
    func image(at time: TimeInterval) -> UIImage? {
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        if let cache, cache.index == lo { return cache.image }
        guard let img = UIImage(data: data.subdata(in: frames[lo].range)) else { return nil }
        cache = (lo, img)
        return img
    }
}
