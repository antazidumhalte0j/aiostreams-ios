import UIKit

// The mini player: the page's `player-frame` (upstream `features/player/mini-player.tsx`), which
// asks the app to draw its video small, docked over the page, as the Android app's MiniPlayer does.
// Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork, read against upstream's own frame.

/// Where the page wants the video, in its own pixels, which are the web view's points.
struct VideoFrame: Equatable {
    var rect: CGRect
    let hidden: Bool
    let animate: Bool
    let draggable: Bool
    let radius: CGFloat
    let bottomRadius: CGFloat
    let subtitles: Bool

    /// The message's frame, or nil for full screen (or anything it can't read).
    static func from(_ message: [String: Any]) -> VideoFrame? {
        guard let frame = message["frame"] as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            guard let value = frame[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return CGFloat(min(max(value.doubleValue, -100_000), 100_000))
        }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
              width > 0, height > 0 else { return nil }
        return VideoFrame(
            rect: CGRect(x: x, y: y, width: width, height: height),
            hidden: frame["hidden"] as? Bool ?? false,
            animate: frame["animate"] as? Bool ?? false,
            draggable: frame["draggable"] as? Bool ?? false,
            radius: max(0, number("radius") ?? 0),
            bottomRadius: max(0, number("bottomRadius") ?? 0),
            subtitles: frame["subtitles"] as? Bool ?? true
        )
    }
}

/**
 * The video and its subtitles, which the page can draw small. Full screen it fills the window
 * beneath the page; framed, it shrinks to the frame and a rounded hole is cut through the page (a
 * mask on the web view) so the video shows where the page draws. The page keeps its touches: a tap
 * on the small video reaches it, and the app reports drags of the video, which the page can't follow.
 */
@MainActor
final class VideoStage {
    /// Holds the video view and the subtitle overlay.
    let view = UIView()
    /// The page, which the hole is cut through.
    weak var web: UIView? {
        didSet { refresh() }
    }

    private let video: UIView
    private let subtitles: UIView
    private let hole = CAShapeLayer()
    private(set) var active = false
    private(set) var frame: VideoFrame?
    private var animator: UIViewPropertyAnimator?

    /// As the page's card moves (`MINI_MOVE_MS`, `MINI_MOVE_EASE`).
    private static let moveSeconds: TimeInterval = 0.22
    private static let moveCurve = (CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.2, y: 1))

    init(video: UIView, subtitles: UIView) {
        self.video = video
        self.subtitles = subtitles
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isHidden = true
        for pane in [video, subtitles] {
            pane.frame = view.bounds
            pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(pane)
        }
        hole.fillRule = .evenOdd
        hole.fillColor = UIColor.black.cgColor
    }

    /// A title started or stopped; it starts full screen until the page says otherwise.
    func show(_ on: Bool) {
        active = on
        if !on { frame = nil }
        refresh()
    }

    func place(_ next: VideoFrame?) {
        frame = next
        refresh(animated: next?.animate == true)
    }

    /// The small video's place in the page, where it can be dragged from.
    var draggableRect: CGRect? {
        guard active, let frame, frame.draggable, !frame.hidden else { return nil }
        return frame.rect
    }

    /// Follows a finger dragging the small video, its top left corner at `origin`.
    func drag(to origin: CGPoint) {
        guard var moved = frame else { return }
        moved.rect.origin = origin
        frame = moved
        refresh()
    }

    /// Lays the stage and the hole out again, as after a layout or orientation change.
    func refresh(animated: Bool = false) {
        guard let container = view.superview else { return }
        animator?.stopAnimation(true)
        animator = nil
        let shown = active ? frame : nil
        view.isHidden = !active || shown?.hidden == true
        let target = shown.flatMap { frame in web.map { container.convert(frame.rect, from: $0) } } ?? container.bounds
        // Full screen it follows the window; framed it stays where the page put it.
        view.autoresizingMask = shown == nil ? [.flexibleWidth, .flexibleHeight] : []
        view.clipsToBounds = shown != nil
        view.layer.cornerRadius = shown.map { max($0.radius, $0.bottomRadius) } ?? 0
        view.layer.maskedCorners = Self.corners(shown)
        subtitles.alpha = shown?.subtitles == false ? 0 : 1
        if animated, shown != nil {
            let (c1, c2) = Self.moveCurve
            let animator = UIViewPropertyAnimator(
                duration: Self.moveSeconds,
                timingParameters: UICubicTimingParameters(controlPoint1: c1, controlPoint2: c2)
            )
            animator.addAnimations { [view] in view.frame = target }
            animator.startAnimation()
            self.animator = animator
        } else {
            view.frame = target
        }
        cutHole(shown, animated: animated)
    }

    /// The corners the radii apply to: the bar's video rounds only its own, a docked one all round.
    private static func corners(_ frame: VideoFrame?) -> CACornerMask {
        guard let frame else { return [] }
        var corners: CACornerMask = []
        if frame.radius > 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if frame.bottomRadius > 0 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    /// Cuts the frame out of the page, or puts the page back whole.
    private func cutHole(_ frame: VideoFrame?, animated: Bool) {
        guard let web else { return }
        guard let frame, !frame.hidden else {
            if web.layer.mask === hole { web.layer.mask = nil }
            return
        }
        let path = UIBezierPath(rect: web.bounds)
        var corners: UIRectCorner = []
        if frame.radius > 0 { corners.formUnion([.topLeft, .topRight]) }
        if frame.bottomRadius > 0 { corners.formUnion([.bottomLeft, .bottomRight]) }
        let radius = max(frame.radius, frame.bottomRadius)
        path.append(UIBezierPath(roundedRect: frame.rect, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: radius, height: radius)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.frame = web.bounds
        if animated, web.layer.mask === hole, let from = hole.path {
            let move = CABasicAnimation(keyPath: "path")
            move.fromValue = from
            move.toValue = path.cgPath
            move.duration = Self.moveSeconds
            let (c1, c2) = Self.moveCurve
            move.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y)
            )
            hole.add(move, forKey: "path")
        }
        hole.path = path.cgPath
        if web.layer.mask !== hole { web.layer.mask = hole }
        CATransaction.commit()
    }
}
