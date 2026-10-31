import SwiftUI
#if os(macOS)
import AppKit
// The shared code uses the UIKit names; on the Mac they are the AppKit types (as in KSPlayer's own macOS module).
typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIView = NSView
#else
import UIKit
#endif

/// What differs between Apple TV, iPhone/iPad and Mac.
enum Platform {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif

    #if os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    static var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// The FFmpeg player (KSPlayer). Its free build ships Apple TV and Mac binaries only, so iPhone and iPad play
    /// through AVPlayer with the server repackaging (or, for unsupported audio, converting) what AVPlayer can't open.
    #if KSPLAYER
    static let hasFFmpeg = true
    #else
    static let hasFFmpeg = false
    #endif

    /// The views are laid out for a 1920×1080 TV seen from the sofa. Other screens scale those sizes down.
    static let scale: CGFloat = {
        #if os(tvOS)
        return 1
        #elseif os(macOS)
        return 0.6
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? 0.42 : 0.62
        #endif
    }()

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static var systemVersion: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return UIDevice.current.systemVersion
        #endif
    }

    /// Plex shows these in its dashboard and uses them to pick a client profile.
    static var plexPlatform: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }

    static var plexDevice: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// Where the decoding happens, for the playback notes.
    static var deviceNoun: String {
        #if os(tvOS)
        return "the Apple TV"
        #elseif os(macOS)
        return "the Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "the iPad" : "the iPhone"
        #endif
    }
}

// MARK: - Layout scale

extension Int {
    /// A TV-sized length, scaled for the current screen.
    var s: CGFloat { CGFloat(self) * Platform.scale }
}

extension Double {
    var s: CGFloat { CGFloat(self) * Platform.scale }
}

extension CGFloat {
    var s: CGFloat { self * Platform.scale }
}

/// Poster grid columns: six fixed columns on the TV, as many as fit elsewhere.
func posterColumns() -> [GridItem] {
    if Platform.isTV { return Array(repeating: GridItem(.fixed(260), spacing: 50), count: 6) }
    return [GridItem(.adaptive(minimum: 260.s, maximum: 300.s), spacing: 50.s, alignment: .top)]
}

// MARK: - AppKit shims

#if os(macOS)
extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension NSImage {
    /// Decoding happens on draw with AppKit; nothing to prepare.
    func preparingForDisplay() -> NSImage? { self }
    var scale: CGFloat { 1 }
}
#endif

// MARK: - Remote-only modifiers

extension View {
    /// Groups focus for the Siri Remote (and the Mac keyboard). Touch screens have no focus engine.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(iOS)
        self
        #else
        focusSection()
        #endif
    }

    /// Arrow keys / remote swipes.
    @ViewBuilder func onRemoteMove(perform action: @escaping (MoveCommandDirection) -> Void) -> some View {
        #if os(iOS)
        self
        #else
        onMoveCommand(perform: action)
        #endif
    }

    /// Menu / Back on the remote, Escape on the Mac.
    @ViewBuilder func onBack(perform action: @escaping () -> Void) -> some View {
        #if os(iOS)
        self
        #else
        onExitCommand(perform: action)
        #endif
    }

    @ViewBuilder func onPlayPause(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }

    /// Horizontal button rows are wider than a phone; let them scroll there.
    @ViewBuilder func scrollsHorizontallyOnSmallScreens() -> some View {
        if Platform.isTV {
            self
        } else {
            ScrollView(.horizontal, showsIndicators: false) { self }
        }
    }
}

#if os(iOS)
/// iOS has no Siri Remote directions; this mirrors the type so shared code compiles.
enum MoveCommandDirection { case up, down, left, right }
#endif

// MARK: - Sheets

/// The remote's Menu button and a swipe down close sheets on Apple TV and iPhone; the Mac needs a button (and a size).
private struct SheetDone: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #elseif os(macOS)
        content
            .frame(minWidth: 640, minHeight: 440)
            .overlay(alignment: .topTrailing) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).padding() }
        #else
        content.overlay(alignment: .topTrailing) { Button("Done") { dismiss() }.padding() }
        #endif
    }
}

extension View {
    func sheetDoneButton() -> some View { modifier(SheetDone()) }
}
