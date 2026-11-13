import AetherEngineFeatures
import AVFoundation
import UIKit

/// The page's subtitle style, in the units mpv and libass share (sizes at a 720-line script).
struct SubtitleLook: Equatable {
    var scale: Double = 1
    var bold = false
    var color = UIColor.white
    var outlineColor = UIColor.black
    var outlineSize: Double = 3
    var shadowSize: Double = 0
    var fontFamily: String?
    var backColor = UIColor.clear
    var box = false
    /// Draws the page's style over a styled file's own colours.
    var forceStyle = false
    /// Percent of the height from the top where the bottom line sits.
    var position: Double = 100

    /// mpv's `sub-font-size` default, at 720 lines.
    static let baseFontSize = 55.0

    init() {}

    init(json: [String: Any]) {
        scale = JSON.number(json["scale"]) ?? 1
        bold = json["bold"] as? Bool ?? false
        color = JSON.color(json["color"]) ?? .white
        outlineColor = JSON.color(json["outlineColor"]) ?? .black
        outlineSize = JSON.number(json["outlineSize"]) ?? 0
        shadowSize = JSON.number(json["shadowSize"]) ?? 0
        fontFamily = SubtitleLook.family(json["font"] as? String)
        backColor = JSON.color(json["backColor"]) ?? .clear
        box = json["box"] as? Bool ?? false
        forceStyle = (json["override"] as? String) == "force"
        position = JSON.number(json["position"]) ?? 100
    }

    /// The page's font names, as iOS knows them.
    static func family(_ name: String?) -> String? {
        switch name {
        case "serif": return "Georgia"
        case "monospace", "serif-monospace": return "Menlo"
        case "casual": return "Chalkboard SE"
        case "cursive": return "Snell Roundhand"
        default: return nil
        }
    }
}

/// Draws the engine's subtitle cues over the video and beneath the page, against the source clock.
final class SubtitleOverlayView: UIView {
    var look = SubtitleLook() { didSet { if look != oldValue { setNeedsDisplay() } } }
    /// Seconds the subtitles show later than the file says.
    var delay: Double = 0 { didSet { refresh() } }
    /// Off while the page's mini player or a menu covers the picture.
    var shown = true { didSet { isHidden = !shown } }
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { setNeedsDisplay() } } }
    var gravity: AVLayerVideoGravity = .resizeAspect { didSet { setNeedsDisplay() } }

    private var cues: [SubtitleCue] = []
    private var time: Double = 0
    private var visible: [Int] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setCues(_ cues: [SubtitleCue]) {
        self.cues = cues
        refresh(force: true)
    }

    func setTime(_ seconds: Double) {
        time = seconds
        refresh()
    }

    func clear() {
        cues = []
        refresh(force: true)
    }

    private var showing: [SubtitleCue] {
        let at = time - delay
        return cues.filter { $0.startTime <= at && at < $0.endTime }
    }

    private func refresh(force: Bool = false) {
        let ids = showing.map(\.id)
        if force || ids != visible {
            visible = ids
            setNeedsDisplay()
        }
    }

    /// Where the picture sits in the view.
    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        switch gravity {
        case .resize: return bounds
        case .resizeAspectFill:
            let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        default:
            return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        }
    }

    override func draw(_ rect: CGRect) {
        let cues = showing
        guard !cues.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        let video = videoRect.intersection(bounds).isNull ? bounds : videoRect
        // Text is sized to what shows of the picture, so a cropped fill doesn't push lines off screen.
        let shownVideo = video.intersection(bounds)
        var bottomStack: [NSAttributedString] = []
        var placed: [(NSAttributedString, Int, CGPoint?)] = []
        let line = bottomLine(video: shownVideo)

        for cue in cues {
            switch cue.body {
            case .image(let image):
                drawImage(image, in: video, below: line, context: context)
            case .text(let text):
                let string = attributed(runs: nil, text: text, height: shownVideo.height)
                route(string, placement: cue.placement, bottom: &bottomStack, placed: &placed)
            case .richText(let runs):
                let string = attributed(runs: runs, text: nil, height: shownVideo.height)
                route(string, placement: cue.placement, bottom: &bottomStack, placed: &placed)
            @unknown default:
                break
            }
        }

        // Bottom lines stack upwards from the page's chosen height.
        var bottom = line
        for string in bottomStack.reversed() {
            let size = measure(string, width: shownVideo.width * 0.92)
            let origin = CGPoint(x: shownVideo.midX - size.width / 2, y: bottom - size.height)
            drawText(string, at: CGRect(origin: origin, size: size), context: context)
            bottom -= size.height
        }

        for (string, alignment, anchor) in placed {
            let size = measure(string, width: shownVideo.width * 0.92)
            let column = (alignment - 1) % 3 // 0 left, 1 centre, 2 right
            let row = (alignment - 1) / 3 // 0 bottom, 1 middle, 2 top
            let margin = shownVideo.height * 0.04
            var point: CGPoint
            if let anchor {
                point = CGPoint(x: video.minX + video.width * anchor.x, y: video.minY + video.height * anchor.y)
            } else {
                let x = [shownVideo.minX + margin, shownVideo.midX, shownVideo.maxX - margin][column]
                let y = [shownVideo.maxY - margin, shownVideo.midY, shownVideo.minY + margin][row]
                point = CGPoint(x: x, y: y)
            }
            let x = [point.x, point.x - size.width / 2, point.x - size.width][column]
            let y = [point.y - size.height, point.y - size.height / 2, point.y][row]
            drawText(string, at: CGRect(x: x, y: y, width: size.width, height: size.height), context: context)
        }
    }

    /// Where the lowest unplaced line's bottom sits. The page's height is a share of the screen
    /// while its controls lift the subtitles over them (`useLiftSubtitles` measures the window),
    /// and of the picture otherwise; the higher of the two clears the controls and stays on the
    /// picture where it can, as on a letterboxed or portrait video.
    private func bottomLine(video: CGRect) -> CGFloat {
        let share = min(max(look.position, 0), 100) / 100
        let onPicture = min(video.minY + video.height * share, video.maxY - video.height * 0.03)
        let onScreen = min(bounds.height * share, bounds.maxY - bounds.height * 0.03)
        return min(onPicture, onScreen)
    }

    private func route(
        _ string: NSAttributedString,
        placement: SubtitleTextPlacement?,
        bottom: inout [NSAttributedString],
        placed: inout [(NSAttributedString, Int, CGPoint?)]
    ) {
        let alignment = placement?.alignment ?? 2
        if placement?.position == nil, alignment == 2 || !(1...9).contains(alignment) {
            bottom.append(string)
        } else {
            placed.append((string, (1...9).contains(alignment) ? alignment : 2, placement?.position))
        }
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        var descriptor: UIFontDescriptor
        if let family = look.fontFamily {
            descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        } else {
            descriptor = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold || look.bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        // libass, which draws mpv's subtitles in the other apps, makes a font's line (ascender to
        // descender) the size it's given, where UIKit makes its em that size. Sized as libass does,
        // each step matches the web and Android apps instead of reading about a fifth larger.
        let nominal = UIFont(descriptor: descriptor, size: size)
        let line = nominal.ascender - nominal.descender
        return line > 0 ? UIFont(descriptor: descriptor, size: size * size / line) : nominal
    }

    private func attributed(runs: [SubtitleTextRun]?, text: String?, height: CGFloat) -> NSAttributedString {
        let size = CGFloat(SubtitleLook.baseFontSize * look.scale) * height / 720
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if let runs {
            for run in runs {
                var attributes = base
                attributes[.font] = font(size: size, bold: run.isBold, italic: run.isItalic)
                var colour = look.color
                if !look.forceStyle, let c = run.color {
                    colour = UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
                }
                attributes[.foregroundColor] = colour
                if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        } else if let text {
            var attributes = base
            attributes[.font] = font(size: size, bold: false, italic: false)
            attributes[.foregroundColor] = look.color
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    private func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        let pad = outlineWidth(for: string) * 2
        let rect = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(rect.width) + pad, height: ceil(rect.height) + pad)
    }

    private func outlineWidth(for string: NSAttributedString) -> CGFloat {
        CGFloat(look.outlineSize) * bounds.height / 720
    }

    private func drawText(_ string: NSAttributedString, at rect: CGRect, context: CGContext) {
        let outline = outlineWidth(for: string)
        let inner = rect.insetBy(dx: outline, dy: outline)
        if look.box {
            context.setFillColor(look.backColor.cgColor)
            context.fill(rect.insetBy(dx: -outline * 2, dy: 0))
        }
        context.saveGState()
        if look.shadowSize > 0 {
            let offset = CGFloat(look.shadowSize) * bounds.height / 720
            context.setShadow(offset: CGSize(width: offset, height: offset), blur: offset, color: UIColor.black.withAlphaComponent(0.8).cgColor)
        }
        if outline > 0, !look.box {
            // The outline first, then the fill over it, as libass draws a border.
            let stroked = NSMutableAttributedString(attributedString: string)
            stroked.addAttributes(
                [.strokeColor: look.outlineColor, .strokeWidth: 200 * outline / max(font(of: string), 1)],
                range: NSRange(location: 0, length: stroked.length)
            )
            stroked.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.setShadow(offset: .zero, blur: 0)
        }
        string.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        context.restoreGState()
    }

    private func font(of string: NSAttributedString) -> CGFloat {
        guard string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return 1 }
        return font.pointSize
    }

    private func drawImage(_ image: SubtitleImage, in video: CGRect, below line: CGFloat, context: CGContext) {
        // `position` is normalised against the subtitle canvas, laid onto the picture.
        var frame = CGRect(
            x: video.minX + image.position.minX * video.width,
            y: video.minY + image.position.minY * video.height,
            width: image.position.width * video.width,
            height: image.position.height * video.height
        )
        // A picture in the lower half rises with the line, as the Android app lifts it, no higher than the top.
        if frame.midY > video.midY, frame.maxY > line {
            frame.origin.y = max(min(frame.minY, video.minY), frame.minY - (frame.maxY - line))
        }
        UIImage(cgImage: image.cgImage).draw(in: frame)
    }
}
