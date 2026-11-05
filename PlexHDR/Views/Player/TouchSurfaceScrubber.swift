#if os(tvOS)
import SwiftUI
import UIKit

/// The Siri Remote's touch surface: while paused, while scrubbing or while the timeline shows, a horizontal pan moves
/// the scrub head (with preview thumbnails) and a click commits it. Swipes up and down stay with the move commands
/// (timeline and panel).
///
/// Remote touches go to the focused view and its ancestors, so the recognizer sits on the window; it only begins while
/// the player can scrub, so the panel and other screens keep their focus swipes.
struct TouchSurfaceScrubber: UIViewRepresentable {
    let c: PlayerController

    func makeCoordinator() -> Coordinator { Coordinator(c) }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ view: HostView, context: Context) {
        context.coordinator.c = c
    }

    static func dismantleUIView(_ view: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var c: PlayerController
        private let pan = UIPanGestureRecognizer()

        init(_ c: PlayerController) {
            self.c = c
            super.init()
            pan.addTarget(self, action: #selector(handle(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            pan.delegate = self
        }

        func attach(to window: UIWindow?) {
            guard let window else { return }
            if pan.view === window { return }
            pan.view?.removeGestureRecognizer(pan)
            window.addGestureRecognizer(pan)
        }

        func detach() {
            pan.view?.removeGestureRecognizer(pan)
            if c.touchScrubbing { c.endTouchScrub() }
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                c.beginTouchScrub()
            case .changed:
                guard c.touchScrubbing else { return }
                let width = max(1, g.view?.bounds.width ?? 1920)
                c.moveTouchScrub(fraction: Double(g.translation(in: g.view).x / width))
            case .ended, .cancelled, .failed:
                if c.touchScrubbing { c.endTouchScrub() }
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, c.canTouchScrub else { return false }
            // Clearly sideways, and a real swipe rather than a resting thumb that shifts while clicking.
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > 250 && abs(v.x) > abs(v.y) * 1.3
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
