import UIKit

/// Underscan for TVs and projectors that crop the picture's edges: the app's windows are scaled
/// down around the screen's middle, so everything, from the pages to what they present and the
/// player, keeps its layout and lands inside the part of the screen the set shows.
enum ScreenFit {
    static let key = "interface.screenMargin"

    /// The scale for the setting, which is a percent of the screen left empty on each side.
    static var scale: CGFloat {
        let margin = min(max(UserDefaults.standard.integer(forKey: key), 0), 6)
        return 1 - CGFloat(margin) * 2 / 100
    }

    @MainActor static func apply() {
        let scale = scale
        let transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.transform != transform {
                window.transform = transform
            }
        }
    }
}
