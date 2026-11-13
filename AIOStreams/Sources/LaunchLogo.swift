import UIKit

/**
 * The web app's launch logo, drawn natively from the app's first frame until the page's own splash
 * shows it (upstream `packages/web/index.html`, which matches the Android app's splash_logo.xml):
 * white on black, 288 points square, centred. A script the app adds says `splash-shown` once the
 * page has drawn its first frames, splash included, and the cover fades into the identical logo
 * beneath; a timeout lifts it if that never comes. Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork.
 */
@MainActor
final class LaunchLogo: UIView {
    /// Tells the app once the page has drawn its first frames, which hold its splash.
    static let script = """
    (() => {
      if (window.top !== window) return;
      const said = () => window.aiostreamsApp && window.aiostreamsApp.send({ type: 'splash-shown' });
      requestAnimationFrame(() => requestAnimationFrame(said));
    })();
    """

    private let logo = CAShapeLayer()
    private var lifted = false
    private static let side: CGFloat = 288
    private static let timeout: TimeInterval = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        logo.fillColor = UIColor.white.cgColor
        logo.path = Self.path()
        layer.addSublayer(logo)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.lift() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The path is in the SVG's 1080-unit box; scale it to 288 points about the centre.
        let scale = Self.side / 1080
        logo.frame = CGRect(x: bounds.midX - Self.side / 2, y: bounds.midY - Self.side / 2,
                            width: Self.side, height: Self.side)
        logo.setAffineTransform(.identity)
        logo.path = Self.path(scale: scale)
    }

    /// Fades out over the page's identical logo; once only.
    func lift() {
        guard !lifted, superview != nil else { return }
        lifted = true
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }

    /// The splash SVG's two shapes (viewBox 0 0 1080 1080), its relative path commands made absolute.
    private static func path(scale: CGFloat = 1) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
        let path = UIBezierPath()
        path.move(to: p(508.34, 338.5))
        path.addLine(to: p(511.48, 338.5))
        path.addCurve(to: p(584.87, 465.62), controlPoint1: p(576.72, 338.5), controlPoint2: p(617.49, 409.12))
        path.addLine(to: p(424.43, 743.5))
        path.addCurve(to: p(349.47, 613.67), controlPoint1: p(357.80, 743.5), controlPoint2: p(316.16, 671.37))
        path.addLine(to: p(508.34, 338.5))
        path.close()
        path.append(UIBezierPath(ovalIn: CGRect(x: 547.53 * scale, y: 545.5 * scale,
                                                width: 194.72 * scale, height: 198 * scale)))
        return path.cgPath
    }
}
