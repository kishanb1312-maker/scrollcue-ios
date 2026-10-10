import AVKit
import SwiftUI
import AVFoundation
import UIKit
import CoreMedia

/// The floating prompter. Renders the script into video frames and feeds them
/// to a sample-buffer Picture in Picture window that floats over other apps
/// (including the camera). iOS doesn't deliver touches to a PiP window, so the
/// system's skip buttons are repurposed: ⏪ scrolls UP, ⏩ scrolls DOWN.
final class PiPManager: NSObject, ObservableObject, PrompterSurface {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published var lastError: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var timebase: CMTimebase?

    weak var engine: PrompterEngine?
    var settings = PrompterSettings() {
        didSet {
            guard settings != oldValue else { return }
            layout = nil
            controller?.canStartPictureInPictureAutomaticallyFromInline = settings.pipAutoStart
            renderNow()
        }
    }

    private(set) var layout: PrompterLayout?
    private var layoutText: String?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var lastRender: CFTimeInterval = 0
    private var pendingRender = false

    /// Fake media duration; the PiP scrubber shows script progress across it.
    private let duration: Double = 600

    var viewportHeight: CGFloat { canvasSize.height }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetRate(tb, rate: 0)
            CMTimebaseSetTime(tb, time: .zero)
            displayLayer.controlTimebase = tb
            timebase = tb
        }
        setupController()
    }

    deinit {
        possibleObservation?.invalidate()
    }

    private func setupController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.requiresLinearPlayback = false
        c.canStartPictureInPictureAutomaticallyFromInline = settings.pipAutoStart
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.isPossible = c.isPictureInPicturePossible }
        }
        controller = c
    }

    func attach(engine: PrompterEngine) {
        self.engine = engine
        engine.pipSurface = self
        engine.pipActive = isActive
        layout = nil
        renderNow()
    }

    func toggle() {
        guard let controller else {
            lastError = "Picture in Picture isn't supported on this device."
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            AudioSession.activate()
            KeepAlive.shared.start()
            renderNow()
            if controller.isPictureInPicturePossible {
                controller.startPictureInPicture()
            } else {
                // The layer may need a frame or two before PiP becomes possible.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, let c = self.controller else { return }
                    if c.isPictureInPicturePossible { c.startPictureInPicture() }
                    else { self.lastError = "Picture in Picture isn't ready yet. Try again in a second." }
                }
            }
        }
    }

    func stop() { controller?.stopPictureInPicture() }

    // MARK: Rendering

    /// Size of the canvas in points before rotation.
    private var canvasSize: CGSize {
        let px = settings.pipShape.pixelSize
        let pt = CGSize(width: px.width / 2, height: px.height / 2)
        return settings.pipRotation % 180 == 0 ? pt : CGSize(width: pt.height, height: pt.width)
    }

    private func ensureLayout() {
        guard let engine else { return }
        if layout != nil && layoutText == engine.tokens.text { return }
        var s = settings
        s.horizontalMargin = settings.pipMargin
        let style = LayoutStyle(settings: s, fontSize: settings.pipFontSize)
        let width = canvasSize.width - CGFloat(settings.pipMargin) * 2
        layout = PrompterLayout(tokens: engine.tokens, style: style, width: width)
        layoutText = engine.tokens.text
    }

    func engineDidUpdate() {
        let now = CACurrentMediaTime()
        // ~30 fps is plenty for PiP; while the window is closed we only keep
        // the frame roughly current so it opens on the right line.
        let interval = isActive ? 1.0 / 30.0 : 0.25
        if now - lastRender >= interval {
            renderNow()
        } else if !pendingRender {
            pendingRender = true
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.pendingRender = false
                self?.renderNow()
            }
        }
    }

    func renderNow() {
        lastRender = CACurrentMediaTime()
        ensureLayout()
        guard let buffer = makePixelBuffer(), let sample = makeSampleBuffer(from: buffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
        if let tb = timebase, let engine {
            CMTimebaseSetTime(tb, time: CMTime(seconds: engine.progress * duration, preferredTimescale: 600))
        }
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        let size = settings.pipShape.pixelSize
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // UIKit coordinates at 2× scale.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 2, y: -2)
        let pt = CGSize(width: size.width / 2, height: size.height / 2)

        // Background (opacity blends toward black — video can't be see-through).
        let bg = settings.backgroundColor.uiColor
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pt))
        ctx.setFillColor(bg.withAlphaComponent(CGFloat(settings.pipOpacity)).cgColor)
        ctx.fill(CGRect(origin: .zero, size: pt))

        // Rotation + mirroring around the centre.
        ctx.translateBy(x: pt.width / 2, y: pt.height / 2)
        ctx.rotate(by: CGFloat(settings.pipRotation) * .pi / 180)
        if settings.pipMirror { ctx.scaleBy(x: -1, y: 1) }
        let canvas = canvasSize
        ctx.translateBy(x: -canvas.width / 2, y: -canvas.height / 2)

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        if let engine, let layout {
            let offset = layout.y(forPosition: engine.position) - canvas.height * CGFloat(settings.pipActiveLinePosition)
            layout.applyProgress(read: engine.readIndex, current: engine.currentWord)
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: canvas))
            layout.draw(in: CGRect(origin: .zero, size: canvas), offset: offset, originX: CGFloat(settings.pipMargin))
            ctx.restoreGState()

            // Active line marker.
            if settings.showActiveLineMarker {
                let y = canvas.height * CGFloat(settings.pipActiveLinePosition)
                let h = layout.style.font.lineHeight
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 1, y: y - h / 2))
                path.addLine(to: CGPoint(x: 8, y: y))
                path.addLine(to: CGPoint(x: 1, y: y + h / 2))
                path.close()
                settings.highlightColor.withAlpha(0.85).setFill()
                path.fill()
            }

            // Progress bar.
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            ctx.fill(CGRect(x: 0, y: canvas.height - 3, width: canvas.width, height: 3))
            ctx.setFillColor(settings.highlightColor.uiColor.cgColor)
            ctx.fill(CGRect(x: 0, y: canvas.height - 3, width: canvas.width * CGFloat(engine.progress), height: 3))

            // Mic / state indicator.
            if settings.pipShowMicIndicator {
                drawIndicator(engine: engine, in: canvas)
            }
        }
        return pb
    }

    private func drawIndicator(engine: PrompterEngine, in canvas: CGSize) {
        let r: CGFloat = 5
        let center = CGPoint(x: canvas.width - 12, y: 12)
        let color: UIColor
        if !engine.isPlaying { color = UIColor.white.withAlphaComponent(0.35) }
        else if engine.micActive {
            color = engine.isHearingSound || engine.settings.scrollMode == .voice ? .systemGreen : .systemOrange
        } else { color = .systemBlue }
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        if engine.micActive {
            // Live input level bar.
            let level = CGFloat(min(max((engine.micLevel + 60) / 60, 0), 1))
            UIColor.white.withAlphaComponent(0.25).setFill()
            UIBezierPath(roundedRect: CGRect(x: center.x - 30, y: center.y - 2, width: 20, height: 4), cornerRadius: 2).fill()
            UIColor.systemGreen.setFill()
            UIBezierPath(roundedRect: CGRect(x: center.x - 30, y: center.y - 2, width: 20 * level, height: 4), cornerRadius: 2).fill()
        }
    }

    private func makeSampleBuffer(from pb: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return nil }
        let now = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - PiP delegates

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async {
            guard let engine = self.engine else { return }
            if playing { engine.play(skipCountdown: true) } else { engine.pause() }
            c.invalidatePlaybackState()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        // A finite range makes iOS show the skip buttons (a live/infinite range hides them).
        CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        !(engine?.isPlaying ?? false)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            // ⏪ = scroll up, ⏩ = scroll down.
            let lines = max(self.settings.pipStepLines, 1)
            let direction = CMTimeGetSeconds(skipInterval) < 0 ? -1 : 1
            self.engine?.moveLines(direction * lines, on: self)
            self.renderNow()
            completionHandler()
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ c: AVPictureInPictureController) -> Bool { false }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        KeepAlive.shared.start()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = true
        engine?.pipActive = true
        c.invalidatePlaybackState()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = false
        engine?.pipActive = false
        KeepAlive.shared.stop()
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        lastError = "Couldn't start Picture in Picture: \(error.localizedDescription)"
        KeepAlive.shared.stop()
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

/// Hosts the sample-buffer layer in the view hierarchy (required for PiP).
struct PiPHostView: UIViewRepresentable {
    let manager: PiPManager

    final class HostView: UIView {
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer.addSublayer(hosted) }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.hosted = manager.displayLayer
        return v
    }

    func updateUIView(_ v: HostView, context: Context) {
        if v.hosted !== manager.displayLayer { v.hosted = manager.displayLayer }
    }
}
