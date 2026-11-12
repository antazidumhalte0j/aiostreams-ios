import SwiftUI
import UIKit

/// Follows a finger sliding across the remote's touch surface, which SwiftUI only reports as
/// separate moves. A pan recognizer on the window watches those touches alongside the focus
/// engine's own. `begin` returns whether to take this swipe; `change` gets how far it has gone
/// across, as a share of the surface's width (negative to the left).
struct SwipeScrub: UIViewRepresentable {
    var begin: () -> Bool
    var change: (_ share: Double) -> Void
    var end: () -> Void

    func makeUIView(context: Context) -> Catcher {
        let view = Catcher()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Catcher, context: Context) {
        view.begin = begin
        view.change = change
        view.end = end
    }

    static func dismantleUIView(_ view: Catcher, coordinator: ()) {
        view.detach()
    }

    final class Catcher: UIView, UIGestureRecognizerDelegate {
        var begin: () -> Bool = { false }
        var change: (Double) -> Void = { _ in }
        var end: () -> Void = {}
        private var pan: UIPanGestureRecognizer?
        private var taken = false

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            detach()
            guard let newWindow else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.allowedPressTypes = []
            pan.cancelsTouchesInView = false
            pan.delegate = self
            newWindow.addGestureRecognizer(pan)
            self.pan = pan
        }

        func detach() {
            guard let pan else { return }
            if taken { end() }
            taken = false
            pan.view?.removeGestureRecognizer(pan)
            self.pan = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                taken = begin()
            case .changed:
                guard taken, let window = pan.view else { return }
                let width = max(window.bounds.width, 1)
                change(Double(pan.translation(in: window).x / width))
            case .ended, .cancelled, .failed:
                if taken { end() }
                taken = false
            default:
                break
            }
        }
    }
}
