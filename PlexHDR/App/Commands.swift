import SwiftUI

/// Menu commands (Mac) that move between tabs. The visible tab bar handles the request and clears it.
@MainActor
final class AppCommands: ObservableObject {
    static let shared = AppCommands()
    enum Request { case search, settings }
    @Published var request: Request?
}

#if os(macOS)
import AppKit

struct LumenCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppCommands.shared.request = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Search") { AppCommands.shared.request = .search }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Playback") {
            PlayPauseCommand()
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }
}

/// Space plays and pauses while a player is open (and is left to text fields otherwise).
private struct PlayPauseCommand: View {
    @ObservedObject private var plex = PlayerPresenter.shared
    @ObservedObject private var iptv = IPTVPlayerPresenter.shared

    var body: some View {
        Button("Play/Pause") { Self.sendSpace() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(plex.request == nil && iptv.request == nil)
    }

    /// The players handle Space on their focused view; the menu item takes the key first, so pass it on to that view.
    private static func sendSpace() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                           isARepeat: false, keyCode: 49) else { return }
        responder.keyDown(with: event)
    }
}
#endif
