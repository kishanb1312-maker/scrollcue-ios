import Foundation
import UIKit
import Combine

/// Anything that shows the script and can drive scrolling (main canvas, camera overlay, PiP).
protocol PrompterSurface: AnyObject {
    var layout: PrompterLayout? { get }
    var viewportHeight: CGFloat { get }
    func engineDidUpdate()
}

/// The heart of the prompter: owns the scroll position, the playback state,
/// and the microphone, and keeps every surface in sync.
final class PrompterEngine: ObservableObject {
    // Published (coarse) state for SwiftUI.
    @Published private(set) var isPlaying = false
    @Published private(set) var cursor = 0
    @Published private(set) var countdown: Int? = nil
    @Published private(set) var micLevel: Float = -80
    @Published private(set) var micActive = false
    @Published private(set) var isHearingSound = false
    @Published private(set) var sessionWords = 0
    @Published private(set) var progress: Double = 0
    @Published var statusMessage: String? = nil

    // Continuous state (not published — updated at 60 Hz).
    private(set) var position: Double = 0
    private(set) var target: Double = 0
    private var isDragging = false

    private(set) var tokens: ScriptTokens
    private var matcher: ScriptMatcher
    private(set) var settings: PrompterSettings
    private var commands: VoiceCommands

    let mic = MicController()
    private var timer: DispatchSourceTimer?
    private var lastTick = CACurrentMediaTime()
    private var lastSoundTime: CFTimeInterval = 0
    private var countdownTimer: Timer?
    private var commandWatermark = 0
    private var dirty = true
    private var playStarted: Date?

    /// Surfaces showing the script. The PiP surface wins while active.
    private var surfaces: [ObjectIdentifier: WeakSurface] = [:]
    weak var primarySurface: PrompterSurface?
    weak var pipSurface: PrompterSurface?
    /// True while the floating window is up: PiP then drives constant/sound scrolling.
    var pipActive = false { didSet { dirty = true } }

    /// The prompter currently on screen, for Shortcut / Back Tap actions.
    static weak var current: PrompterEngine?

    var onWordsSpoken: ((Int) -> Void)?
    var onMirrorCommand: (() -> Void)?
    var onSessionEnded: ((Double) -> Void)?

    init(text: String, settings: PrompterSettings, startWord: Int = 0) {
        tokens = ScriptTokens(text: text)
        matcher = ScriptMatcher(tokens: tokens)
        self.settings = settings
        commands = VoiceCommands(settings: settings)
        let start = min(max(startWord, 0), max(tokens.count - 1, 0))
        cursor = start
        position = Double(start)
        target = Double(start)

        mic.onLevel = { [weak self] db in self?.handleLevel(db) }
        mic.onTranscript = { [weak self] words in self?.handleTranscript(words) }
        mic.onSegmentReset = { [weak self] in
            DispatchQueue.main.async { self?.commandWatermark = 0 }
        }
        mic.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.statusMessage = msg }
        }
        startTimer()
        updateProgress()
        PrompterEngine.current = self
    }

    deinit {
        timer?.cancel()
        countdownTimer?.invalidate()
        mic.stop()
    }

    // MARK: Surfaces

    func register(_ surface: PrompterSurface, primary: Bool = true) {
        surfaces[ObjectIdentifier(surface)] = WeakSurface(surface: surface)
        if primary { primarySurface = surface }
        dirty = true
    }

    func unregister(_ surface: PrompterSurface) {
        surfaces.removeValue(forKey: ObjectIdentifier(surface))
        if primarySurface === surface {
            primarySurface = surfaces.values.compactMap(\.surface).first { $0 !== pipSurface }
        }
    }

    private var drivingSurface: PrompterSurface? {
        if pipActive, let pip = pipSurface, pip.layout != nil { return pip }
        return primarySurface
    }

    func setNeedsRedraw() { dirty = true }

    // MARK: Text & settings

    func update(text: String) {
        guard text != tokens.text else { return }
        tokens = ScriptTokens(text: text)
        matcher = ScriptMatcher(tokens: tokens)
        cursor = min(cursor, max(tokens.count - 1, 0))
        position = min(position, Double(tokens.count))
        target = position
        dirty = true
    }

    func update(settings new: PrompterSettings) {
        let old = settings
        settings = new
        commands = VoiceCommands(settings: new)
        dirty = true
        if isPlaying && (old.scrollMode != new.scrollMode || old.speechLocale != new.speechLocale) {
            startMicIfNeeded()
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying || countdown != nil ? pause() : play() }

    func play(skipCountdown: Bool = false) {
        guard !isPlaying, countdown == nil else { return }
        if position >= Double(tokens.count) - 0.5 { jump(toWord: 0) }
        let seconds = settings.countdownSeconds
        if seconds > 0 && !skipCountdown {
            countdown = seconds
            countdownTimer?.invalidate()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let next = (self.countdown ?? 1) - 1
                if next <= 0 {
                    t.invalidate()
                    self.countdown = nil
                    self.beginPlaying()
                } else {
                    self.countdown = next
                }
            }
            RunLoop.main.add(countdownTimer!, forMode: .common)
        } else {
            beginPlaying()
        }
    }

    private func beginPlaying() {
        isPlaying = true
        playStarted = Date()
        lastSoundTime = 0
        if settings.scrollMode == .voice {
            // Resume voice tracking from what's on screen right now.
            cursor = Int(target.rounded())
        }
        startMicIfNeeded()
        dirty = true
    }

    func pause() {
        countdownTimer?.invalidate()
        countdown = nil
        guard isPlaying else { return }
        isPlaying = false
        mic.stop()
        micActive = false
        isHearingSound = false
        if let started = playStarted { onSessionEnded?(Date().timeIntervalSince(started)) }
        playStarted = nil
        dirty = true
    }

    private func startMicIfNeeded() {
        mic.stop()
        micActive = false
        switch settings.scrollMode {
        case .constant:
            return
        case .sound:
            Permissions.requestMic { [weak self] ok in
                guard let self, self.isPlaying else { return }
                if ok { self.mic.start(speech: false, locale: .current); self.micActive = self.mic.isRunning }
                else { self.statusMessage = "Microphone access is off. Enable it in Settings › ScrollCue." }
            }
        case .voice:
            Permissions.requestMic { [weak self] ok in
                guard let self else { return }
                guard ok else { self.statusMessage = "Microphone access is off. Enable it in Settings › ScrollCue."; return }
                Permissions.requestSpeech { [weak self] ok in
                    guard let self, self.isPlaying else { return }
                    guard ok else { self.statusMessage = "Speech recognition is off. Enable it in Settings › ScrollCue, or use Sound mode."; return }
                    let locale = MicController.resolveLocale(setting: self.settings.speechLocale, text: self.tokens.text)
                    self.mic.start(speech: true, locale: locale)
                    self.micActive = self.mic.isRunning
                }
            }
        }
    }

    // MARK: Navigation

    func jump(toWord index: Int) {
        let i = min(max(index, 0), tokens.count)
        cursor = min(i, max(tokens.count - 1, 0))
        target = Double(i)
        commandWatermark = Int.max // ignore the rest of the current utterance
        dirty = true
        updateProgress()
    }

    func restart() { jump(toWord: 0); position = 0 }
    func goToEnd() { jump(toWord: tokens.count) }
    func nextSentence() { jump(toWord: tokens.nextSentenceStart(after: Int(target.rounded()))) }
    func previousSentence() { jump(toWord: tokens.previousSentenceStart(before: Int(target.rounded()))) }

    /// Scrolls by whole lines on the given surface (PiP skip buttons, arrow keys).
    func moveLines(_ delta: Int, on surface: PrompterSurface? = nil) {
        guard let layout = (surface ?? drivingSurface)?.layout else { return }
        let p = layout.position(movingLines: delta, from: target)
        jump(toWord: Int(p.rounded()))
    }

    // MARK: Manual dragging

    func beginDrag() { isDragging = true }

    func drag(byPoints dy: CGFloat, on surface: PrompterSurface) {
        guard let layout = surface.layout else { return }
        let y = layout.y(forPosition: position) + dy
        position = min(max(layout.position(forY: y), 0), Double(tokens.count))
        target = position
        dirty = true
    }

    func endDrag() {
        isDragging = false
        cursor = min(Int(position.rounded()), max(tokens.count - 1, 0))
        commandWatermark = Int.max
        updateProgress()
    }

    // MARK: Speech & sound

    private func handleLevel(_ db: Float) {
        micLevel = db
        if pipActive { dirty = true }
        let hearing = Double(db) > settings.soundThreshold
        if hearing { lastSoundTime = CACurrentMediaTime() }
        let active = CACurrentMediaTime() - lastSoundTime < settings.soundHangTime
        if active != isHearingSound { isHearingSound = active }
    }

    private func handleTranscript(_ words: [String]) {
        guard isPlaying, settings.scrollMode == .voice else { return }

        if settings.voiceCommandsEnabled {
            if commandWatermark == Int.max { commandWatermark = words.count }
            if words.count < commandWatermark { commandWatermark = 0 }
            let fresh = Array(words.dropFirst(commandWatermark)).map(ScriptTokens.normalize).filter { !$0.isEmpty }
            if let cmd = commands.detect(in: fresh), !commandIsInScript(fresh) {
                commandWatermark = words.count
                perform(cmd)
                return
            }
        }

        if let next = matcher.match(transcript: words, cursor: cursor) {
            let advanced = next - cursor
            cursor = min(next, tokens.count)
            target = Double(cursor)
            sessionWords += advanced
            onWordsSpoken?(advanced)
            dirty = true
            updateProgress()
            if cursor >= tokens.count { pause() }
        }
    }

    /// True if the words that triggered a command are actually the next words of the script.
    private func commandIsInScript(_ spoken: [String]) -> Bool {
        let upcoming = tokens.words[min(cursor, tokens.count)..<min(cursor + 8, tokens.count)].map(\.normalized)
        let lastTwo = spoken.suffix(2)
        guard !lastTwo.isEmpty else { return false }
        let joined = upcoming.joined(separator: " ")
        return joined.contains(lastTwo.joined(separator: " "))
    }

    private func perform(_ cmd: VoiceCommands.Command) {
        switch cmd {
        case .next, .nextSentence: nextSentence()
        case .back, .previousSentence: previousSentence()
        case .start: restart()
        case .finish: goToEnd()
        case .mirror: onMirrorCommand?()
        }
    }

    // MARK: Ticking

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        lastTick = CACurrentMediaTime()
    }

    private var lastWatchdog: CFTimeInterval = 0

    private func tick() {
        let now = CACurrentMediaTime()
        if pipActive && now - lastWatchdog > 5 {
            // Keep the floating prompter alive and listening if another app interrupted audio.
            lastWatchdog = now
            KeepAlive.shared.restartIfNeeded()
            if isPlaying && settings.scrollMode != .constant && !mic.isRunning { startMicIfNeeded() }
        }
        let dt = min(now - lastTick, 0.1)
        lastTick = now

        if isPlaying && !isDragging {
            switch settings.scrollMode {
            case .constant:
                advance(points: settings.constantSpeed, dt: dt)
            case .sound:
                if isHearingSound { advance(points: settings.soundSpeed, dt: dt) }
            case .voice:
                break
            }
        }

        if !isDragging {
            let diff = target - position
            if abs(diff) > 0.0005 {
                // Ease toward the target; constant scrolling tracks it tightly.
                let k = settings.scrollMode == .voice || !isPlaying ? 7.0 : 20.0
                position += diff * min(1, dt * k)
                dirty = true
            } else if position != target {
                position = target
                dirty = true
            }
        }

        if dirty {
            dirty = false
            for s in surfaces.values.compactMap(\.surface) { s.engineDidUpdate() }
            if let pip = pipSurface, surfaces[ObjectIdentifier(pip)] == nil { pip.engineDidUpdate() }
        }
    }

    private func advance(points speed: Double, dt: Double) {
        guard let surface = drivingSurface, let layout = surface.layout else { return }
        // Speed is defined for 40pt text; scale so it feels the same at any size.
        let scale = Double(layout.style.font.pointSize) / 40.0
        let y = layout.y(forPosition: target) + CGFloat(speed * scale * dt)
        let newTarget = layout.position(forY: y)
        if newTarget >= Double(tokens.count) - 0.001 {
            target = Double(tokens.count)
            pause()
        } else {
            target = newTarget
        }
        let newCursor = min(Int(target), max(tokens.count - 1, 0))
        if newCursor != cursor { cursor = newCursor; updateProgress() }
        dirty = true
    }

    private func updateProgress() {
        let p = tokens.count > 0 ? Double(cursor) / Double(tokens.count) : 0
        if abs(p - progress) > 0.001 || p == 0 || p == 1 { progress = p }
    }

    /// Which words to dim / highlight right now.
    var readIndex: Int {
        settings.scrollMode == .voice ? cursor : Int(position)
    }

    var currentWord: Int? {
        guard settings.scrollMode == .voice, isPlaying, cursor < tokens.count else { return nil }
        return cursor
    }
}

private struct WeakSurface {
    weak var surface: PrompterSurface?
}
