import SwiftUI
import UIKit

/// Keyboard / Bluetooth-remote actions the canvas can trigger.
struct RemoteActions {
    var toggleRecord: (() -> Void)?
    var toggleMirror: (() -> Void)?
    var speedUp: (() -> Void)?
    var speedDown: (() -> Void)?
}

/// UIKit view that draws the script and handles drag, tap-to-jump and hardware keys.
final class PrompterCanvasView: UIView, PrompterSurface {
    weak var engine: PrompterEngine? {
        didSet {
            oldValue?.unregister(self)
            if window != nil { engine?.register(self) }
        }
    }
    var settings = PrompterSettings() { didSet { if settings != oldValue { settingsChanged(old: oldValue) } } }
    var remote = RemoteActions()
    /// Background drawn behind the text (camera overlay uses translucency).
    var backgroundAlpha: CGFloat = 1

    private(set) var layout: PrompterLayout?
    private var layoutTokensText: String?
    var viewportHeight: CGFloat { bounds.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            engine?.register(self)
            DispatchQueue.main.async { self.becomeFirstResponder() }
        } else {
            engine?.unregister(self)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildLayoutIfNeeded()
    }

    private func settingsChanged(old: PrompterSettings) {
        applyMirror()
        rebuildLayoutIfNeeded(force: true)
        setNeedsDisplay()
    }

    private func applyMirror() {
        transform = CGAffineTransform(scaleX: settings.mirrorHorizontal ? -1 : 1,
                                      y: settings.mirrorVertical ? -1 : 1)
    }

    private var lastStyle: LayoutStyle?
    private var lastWidth: CGFloat = 0

    func rebuildLayoutIfNeeded(force: Bool = false) {
        guard let engine, bounds.width > 0 else { return }
        let width = bounds.width - CGFloat(settings.horizontalMargin) * 2
        let style = LayoutStyle(settings: settings)
        if !force, layout != nil, lastStyle == style, lastWidth == width, layoutTokensText == engine.tokens.text { return }
        if layout != nil, lastStyle == style, lastWidth == width, layoutTokensText == engine.tokens.text { return }
        layout = PrompterLayout(tokens: engine.tokens, style: style, width: width)
        layoutTokensText = engine.tokens.text
        lastStyle = style
        lastWidth = width
        engine.setNeedsRedraw()
        setNeedsDisplay()
    }

    func engineDidUpdate() {
        if let engine, layoutTokensText != engine.tokens.text { rebuildLayoutIfNeeded(force: true) }
        setNeedsDisplay()
    }

    /// Layout y that sits at the top of the viewport.
    private var offset: CGFloat {
        guard let engine, let layout else { return 0 }
        return layout.y(forPosition: engine.position) - bounds.height * CGFloat(settings.activeLinePosition)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bg = settings.backgroundColor.withAlpha(settings.backgroundOpacity * Double(backgroundAlpha))
        ctx.setFillColor(bg.cgColor)
        ctx.fill(bounds)
        guard let engine, let layout else { return }

        layout.applyProgress(read: engine.readIndex, current: engine.currentWord)
        layout.draw(in: bounds, offset: offset, originX: CGFloat(settings.horizontalMargin))

        if settings.showActiveLineMarker {
            let y = bounds.height * CGFloat(settings.activeLinePosition)
            let h = layout.style.font.lineHeight * 1.1
            let marker = UIBezierPath()
            marker.move(to: CGPoint(x: 2, y: y - h / 2))
            marker.addLine(to: CGPoint(x: 12, y: y))
            marker.addLine(to: CGPoint(x: 2, y: y + h / 2))
            marker.close()
            settings.highlightColor.withAlpha(0.85).setFill()
            marker.fill()
        }
    }

    // MARK: Gestures

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let engine else { return }
        switch g.state {
        case .began:
            engine.beginDrag()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            engine.drag(byPoints: -t.y, on: self)
        default:
            engine.endDrag()
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard settings.tapToJump, let engine, let layout else { return }
        let p = g.location(in: self)
        let point = CGPoint(x: p.x - CGFloat(settings.horizontalMargin), y: p.y + offset)
        guard let first = layout.lines.first, let last = layout.lines.last,
              point.y >= first.rect.minY, point.y <= last.rect.maxY else { return }
        if let i = layout.wordIndex(at: point) { engine.jump(toWord: i) }
    }

    // MARK: Hardware keys (keyboards & Bluetooth remotes)

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let engine else { continue }
            handled = true
            switch key.keyCode {
            case .keyboardSpacebar, .keyboardReturnOrEnter, .keypadEnter:
                engine.togglePlay()
            case .keyboardUpArrow, .keyboardPageUp:
                engine.moveLines(-(key.keyCode == .keyboardPageUp ? 4 : 1), on: self)
            case .keyboardDownArrow, .keyboardPageDown:
                engine.moveLines(key.keyCode == .keyboardPageDown ? 4 : 1, on: self)
            case .keyboardLeftArrow:
                engine.previousSentence()
            case .keyboardRightArrow:
                engine.nextSentence()
            case .keyboardHome:
                engine.restart()
            case .keyboardEnd:
                engine.goToEnd()
            default:
                switch key.charactersIgnoringModifiers.lowercased() {
                case "m": remote.toggleMirror?()
                case "r": remote.toggleRecord?()
                case "+", "=": remote.speedUp?()
                case "-", "_": remote.speedDown?()
                case "s", "0": engine.restart()
                default: handled = false
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

struct PrompterCanvas: UIViewRepresentable {
    let engine: PrompterEngine
    let settings: PrompterSettings
    var backgroundAlpha: CGFloat = 1
    var remote = RemoteActions()

    func makeUIView(context: Context) -> PrompterCanvasView {
        let v = PrompterCanvasView()
        v.settings = settings
        v.backgroundAlpha = backgroundAlpha
        v.remote = remote
        v.engine = engine
        return v
    }

    func updateUIView(_ v: PrompterCanvasView, context: Context) {
        v.remote = remote
        v.backgroundAlpha = backgroundAlpha
        v.settings = settings
        if v.engine !== engine { v.engine = engine }
        v.setNeedsDisplay()
    }

    static func dismantleUIView(_ v: PrompterCanvasView, coordinator: ()) {
        v.engine?.unregister(v)
    }
}
