import AetherEngineFeatures
@preconcurrency import AVKit
import Combine
import CoreMedia
import UIKit

/// AVKit owns the floating window. Controllers are prepared while a title plays, so iOS can start
/// PiP during a real app switch, with Settings' Start PiP Automatically, as well as from the page's
/// Picture in Picture button. Ported from the 9pbpsvr6f9-alt/aiostreams-ios fork.
@MainActor
final class PictureInPicture: NSObject {
    private let engine: AetherEngine
    private let channel: PlayerChannel
    private let send: ([String: Any]) -> Void
    private var controller: AVPictureInPictureController?
    private var sourceKey: ObjectIdentifier?
    private var softwareSource: SoftwarePiPSource?
    private var retired: [ObjectIdentifier: (AVPictureInPictureController, SoftwarePiPSource?)] = [:]
    private var bag = Set<AnyCancellable>()
    private var starting = false
    private var restoring = false
    private var wasActive = false
    private var backgrounded = false
    private var manualRequest = false
    var automaticEnabled = true { didSet { refresh() } }
    var changed: (Bool) -> Void = { _ in }
    var restore: () -> Void = {}
    var failed: () -> Void = {}

    init(engine: AetherEngine, channel: PlayerChannel, send: @escaping ([String: Any]) -> Void) {
        self.engine = engine
        self.channel = channel
        self.send = send
        super.init()
        engine.$currentAVPlayer.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        engine.$softwarePiPSource.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        engine.$hasFirstFrameReadyForDisplay.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.backgrounded = true
            }.store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                let returned = self.backgrounded
                self.backgrounded = false
                let fromWindow = self.active || self.starting
                if returned && fromWindow { self.stopForRestore() }
                if returned {
                    // A background WebKit process can miss didStop's message. Always resync inline UI.
                    self.changed(false)
                    self.send(["type": "pip", "value": false])
                }
                self.refresh()
            }.store(in: &bag)
    }

    var active: Bool { controller?.isPictureInPictureActive == true }
    private var policy: PictureInPicturePolicy {
        PictureInPicturePolicy(supported: AVPictureInPictureController.isPictureInPictureSupported(),
                               hasMedia: channel.hasMedia,
                               playing: engine.state == .playing,
                               sourceAvailable: engine.nativePlayerLayer != nil || engine.softwarePiPSource != nil,
                               automaticEnabled: automaticEnabled)
    }

    func refresh() {
        guard policy.prepares else {
            if active || starting {
                let p = policy
                AppLog.warn("pip", "no longer eligible (media \(p.hasMedia), source \(p.sourceAvailable)); closing it")
            }
            clear(); return
        }
        let native = engine.nativePlayerLayer
        let software = native == nil ? engine.softwarePiPSource : nil
        let key = native.map { ObjectIdentifier($0) } ?? software.map { ObjectIdentifier($0.layer) }
        if key != sourceKey {
            if active || starting {
                AppLog.warn("pip", "the video's picture changed under the window (\(native != nil ? "native" : software != nil ? "software" : "none")); closing it")
            }
            clear()
            sourceKey = key
            softwareSource = software // AVKit's sample-buffer content source holds its delegate weakly.
            controller = native.flatMap { AVPictureInPictureController(playerLayer: $0) }
                ?? software?.makePictureInPictureController()
            controller?.delegate = self
        }
        // AVKit owns automatic entry and honors iOS's Start PiP Automatically preference.
        // Do not emulate a manual button press from didEnterBackground to override that setting.
        controller?.canStartPictureInPictureAutomaticallyFromInline = policy.automatic
    }

    func toggle() {
        guard !starting else { return }
        if active { stopForRestore(); return }
        refresh()
        guard policy.prepares, let controller, controller.isPictureInPicturePossible else { failed(); return }
        manualRequest = true
        starting = true
        controller.startPictureInPicture()
    }

    func stopForRestore() {
        restoring = true
        controller?.stopPictureInPicture()
    }

    func clear() {
        if let controller {
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            if controller.isPictureInPictureActive || starting {
                retired[ObjectIdentifier(controller)] = (controller, softwareSource)
                controller.stopPictureInPicture()
            } else { controller.delegate = nil }
        }
        controller = nil
        sourceKey = nil
        softwareSource = nil
        starting = false
        restoring = false
        wasActive = false
        manualRequest = false
        setActive(false)
    }

    private func setActive(_ on: Bool) {
        engine.pictureInPictureActive = on
        if !on {
            engine.setNativeSubtitleRendering(false)
            engine.currentAVPlayer?.currentItem?.textStyleRules = nil
        }
        changed(on)
        send(["type": "pip", "value": on])
    }
}

extension PictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { controller.stopPictureInPicture(); return }
        AppLog.info("pip", "starting (\(manualRequest ? "button" : "automatic"))")
        starting = true
        restoring = false
        engine.pictureInPictureActive = true // Arm the engine before its background lifecycle decision.
        engine.currentAVPlayer?.currentItem?.textStyleRules = Self.captionRules(channel.subtitleLook)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { controller.stopPictureInPicture(); return }
        AppLog.info("pip", "started")
        starting = false
        manualRequest = false
        wasActive = true
        setActive(true)
        engine.setNativeSubtitleRendering(true)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === self.controller else { retired.removeValue(forKey: ObjectIdentifier(controller)); return }
        AppLog.warn("pip", "could not start: \(error.localizedDescription)")
        let report = manualRequest
        starting = false
        manualRequest = false
        wasActive = false
        setActive(false)
        if report { failed() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { retired.removeValue(forKey: ObjectIdentifier(controller)); return }
        let pause = PictureInPicturePolicy.pausesWhenStopped(wasActive: wasActive, restoring: restoring)
        AppLog.info("pip", restoring ? "closed to return to the app" : "closed")
        starting = false
        wasActive = false
        restoring = false
        setActive(false)
        if pause { channel.pauseFromPictureInPicture() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === self.controller else { completionHandler(false); return }
        AppLog.info("pip", "returning to the app")
        restoring = true
        restore()
        changed(false)
        send(["type": "pip", "value": false])
        completionHandler(true)
    }
}

extension PictureInPicture {
    /// The AVPlayer path's window draws the stream's WebVTT captions in the system's boxed style.
    /// These rules ask for the app's look instead: its text colour and font, no box unless the look
    /// has one, and an outline (or a shadow) edge. Settings > Accessibility > Subtitles & Captioning
    /// can still win over them. The software path draws the system caption style into the frames
    /// and has no hook for the app's look in AetherEngine 7.64.0 or 7.65.0.
    static func captionRules(_ look: SubtitleLook) -> [AVTextStyleRule] {
        func argb(_ color: UIColor) -> [NSNumber] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return [1, 1, 1, 1] }
            return [a, r, g, b].map { NSNumber(value: Double($0)) }
        }
        let edge: CFString = look.outlineSize > 0 ? kCMTextMarkupCharacterEdgeStyle_Uniform
            : look.shadowSize > 0 ? kCMTextMarkupCharacterEdgeStyle_DropShadow
            : kCMTextMarkupCharacterEdgeStyle_None
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: argb(look.color),
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: argb(look.box ? look.backColor : .clear),
            kCMTextMarkupAttribute_BackgroundColorARGB as String: argb(.clear),
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: edge as String,
        ]
        if look.bold { attributes[kCMTextMarkupAttribute_BoldStyle as String] = true }
        if let family = look.fontFamily { attributes[kCMTextMarkupAttribute_FontFamilyName as String] = family }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
    }
}

/// Whether the window can be offered and started by itself, apart from AVKit.
struct PictureInPicturePolicy {
    var supported: Bool
    var hasMedia: Bool
    var playing: Bool
    var sourceAvailable: Bool
    var automaticEnabled: Bool

    var prepares: Bool { supported && hasMedia && sourceAvailable }
    var automatic: Bool { prepares && playing && automaticEnabled }
    /// Closing the window by its own button pauses, as other apps do; going back to the app doesn't.
    static func pausesWhenStopped(wasActive: Bool, restoring: Bool) -> Bool { wasActive && !restoring }
}
