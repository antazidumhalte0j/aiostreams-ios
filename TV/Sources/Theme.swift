import SwiftUI
import UIKit

/// The web app's look (packages/ui/theme.css, packages/web/src/styles.css), at a TV's scale:
/// the web app lays a TV out at 1280 × 720, and tvOS lays out at 1920 × 1080 points,
/// so every size here is the web app's CSS pixels × 1.5.
enum Theme {
    static let scale: CGFloat = 1.5

    /// CSS pixels to points.
    static func px(_ value: CGFloat) -> CGFloat { value * scale }

    /// The page's colour; the theme's background where the web app's theme set one.
    static var background: Color { custom.background ?? Color(red: 7 / 255, green: 7 / 255, blue: 7 / 255) }
    /// `--ring`, brand-400: the one focus mark everywhere, a step lighter than the accent.
    static var ring: Color { custom.ring ?? Color(red: 159 / 255, green: 146 / 255, blue: 255 / 255) }
    static var brand500: Color { custom.accent ?? Color(red: 97 / 255, green: 82 / 255, blue: 223 / 255) }

    /// The web app's theme colours (Settings > Theme), applied as the app starts and when they change.
    struct Custom: Equatable {
        var accent: Color?
        var ring: Color?
        var background: Color?
    }

    private(set) static var custom = Custom()

    /// Sets the theme from the synced `#rrggbb` colours; nil keeps the default.
    static func apply(accent: String?, background: String?) {
        // The web app takes a colour typed without its #.
        let hex = { (text: String) in JSON.color(text.hasPrefix("#") ? text : "#" + text) }
        let accentColor = accent.flatMap(hex)
        custom = Custom(
            accent: accentColor.map(Color.init),
            // brand-400 to the accent's 500: a third of the way to white.
            ring: accentColor.map { Color($0.mixed(with: .white, by: 0.35)) },
            background: background.flatMap(hex).map(Color.init)
        )
    }
    static let gray200 = Color(white: 209 / 255)
    static let gray300 = Color(white: 202 / 255)
    static let gray400 = Color(white: 143 / 255)
    static let gray500 = Color(white: 90 / 255)
    static let gray700 = Color(white: 54 / 255)
    static let gray800 = Color(white: 28 / 255)
    static let gray900 = Color(white: 16 / 255)
    static let star = Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255)

    /// Focus rings are 3 px on a TV, outside what they ring, 2 px off it.
    static let ringWidth = px(3)
    static let ringOffset = px(2)

    enum Weight { case regular, medium, semibold, bold, extrabold }

    /// Inter, bundled, by PostScript name so each weight resolves exactly; sizes in CSS pixels.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "Inter-Regular"
        case .medium: name = "Inter-Medium"
        case .semibold: name = "Inter-SemiBold"
        case .bold: name = "Inter-Bold"
        case .extrabold: name = "Inter-ExtraBold"
        }
        return .custom(name, fixedSize: px(size))
    }

    // Tailwind's text sizes, which the web app's components use.
    static let xs: CGFloat = 12
    static let sm: CGFloat = 14
    static let base: CGFloat = 16
    static let lg: CGFloat = 18
    static let xl: CGFloat = 20
    static let xl2: CGFloat = 24
    static let xl3: CGFloat = 30
}

/// Reads focus inside a button style, where only a view can.
struct Focused<Content: View>: View {
    @Environment(\.isFocused) private var focused
    let content: (Bool) -> Content
    var body: some View { content(focused) }
}

/// The web app's ring, round a capsule or any rounded shape, just outside it.
struct FocusRing: ViewModifier {
    let focused: Bool
    var radius: CGFloat? = nil

    func body(content: Content) -> some View {
        content.overlay {
            if focused {
                Group {
                    if let radius {
                        RoundedRectangle(cornerRadius: radius + Theme.ringOffset, style: .continuous)
                            .stroke(Theme.ring, lineWidth: Theme.ringWidth)
                    } else {
                        Capsule().stroke(Theme.ring, lineWidth: Theme.ringWidth)
                    }
                }
                .padding(-(Theme.ringOffset + Theme.ringWidth / 2))
            }
        }
    }
}

extension View {
    func focusRing(_ focused: Bool, radius: CGFloat? = nil) -> some View {
        modifier(FocusRing(focused: focused, radius: radius))
    }
}

/// The white pill a hero's or title's main action is: `Play`, `Resume from …`.
struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(Theme.font(15, .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, Theme.px(20))
                .frame(height: Theme.px(40))
                .background(Capsule().fill(.white))
                .focusRing(focused)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// An outlined pill beside the main one: `More info`, `Trailer`.
struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(Theme.font(15, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.px(18))
                .frame(height: Theme.px(40))
                .background(Capsule().fill(focused ? Color.white.opacity(0.12) : Color.black.opacity(0.25)))
                .overlay(Capsule().stroke(Theme.gray700, lineWidth: Theme.px(1)))
                .focusRing(focused)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// A gray pill for lesser actions: `Other user`, `Quick Connect`.
struct SoftPillStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(Theme.font(15, .medium))
                .foregroundStyle(selected || focused ? .white : Theme.gray200)
                .padding(.horizontal, Theme.px(13))
                .frame(height: Theme.px(32))
                .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Theme.gray800))
                .focusRing(focused)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// A round outlined icon button, as a title's actions are.
struct CircleIconStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(.system(size: Theme.px(18), weight: .medium))
                .foregroundStyle(.white)
                .frame(width: Theme.px(40), height: Theme.px(40))
                .background(Circle().fill(active ? Color.white.opacity(0.18) : (focused ? Color.white.opacity(0.12) : Color.white.opacity(0.06))))
                .overlay(Circle().stroke(Theme.gray700, lineWidth: Theme.px(1)))
                .focusRing(focused)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// A picture that takes focus: the ring goes round it, outside, so none of it is hidden.
struct CardStyle: ButtonStyle {
    var radius: CGFloat = Theme.px(8)

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .focusRing(focused, radius: radius)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// A row in a list or sheet: a soft fill when focused, ringed.
struct RowStyle: ButtonStyle {
    var radius: CGFloat = Theme.px(12)

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(focused ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: Theme.px(1))
                )
                .focusRing(focused, radius: radius)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// Dots between a title's facts: `2025 • ★ 8.3 • Drama, Crime`.
struct MetaLine: View {
    let parts: [AnyView]

    var body: some View {
        HStack(spacing: Theme.px(10)) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Circle().fill(Theme.gray500).frame(width: Theme.px(4), height: Theme.px(4))
                }
                part
            }
        }
    }
}

/// The AIOStreams mark, white.
struct BrandLogo: View {
    var height: CGFloat = Theme.px(32)

    var body: some View {
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
    }
}

private extension UIColor {
    func mixed(with other: UIColor, by share: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * share, green: g1 + (g2 - g1) * share,
                       blue: b1 + (b2 - b1) * share, alpha: a1 + (a2 - a1) * share)
    }
}
