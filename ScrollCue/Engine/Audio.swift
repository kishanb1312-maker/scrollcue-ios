import AVFoundation
import Speech
import NaturalLanguage

enum AudioSession {
    /// One shared configuration: record + play, mixing with other apps so the
    /// camera / Instagram / etc. can keep running while ScrollCue floats on top.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 0x4 = Bluetooth hands-free mic support. Written as a raw value because its
            // Swift name changed in iOS 26 (allowBluetooth → allowBluetoothHFP); this
            // compiles cleanly on every Xcode version.
            let bluetoothHFP = AVAudioSession.CategoryOptions(rawValue: 0x4)
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, bluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }
}

/// Plays a looping silent track so iOS keeps the app running (and the PiP
/// prompter scrolling and responding to its buttons) while another app,
/// like Camera, is in front. Mixes with other audio, so it never interrupts
/// anything.
final class KeepAlive: NSObject {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?
    private var wanted = false

    var isPlaying: Bool { player?.isPlaying ?? false }

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func start() {
        wanted = true
        AudioSession.activate()
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWAV(seconds: 2))
            player?.numberOfLoops = -1
            player?.volume = 0.01
            player?.prepareToPlay()
        }
        if player?.isPlaying != true { player?.play() }
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
    }

    /// Called after interruptions (e.g. the Camera app grabbing audio) and by the PiP heartbeat.
    func restartIfNeeded() {
        guard wanted, player?.isPlaying != true else { return }
        AudioSession.activate()
        if player == nil { start() } else { player?.play() }
    }

    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            DispatchQueue.main.async { PiPDiagnostics.shared.interruptions += 1 }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.restartIfNeeded() }
    }

    @objc private func mediaReset() {
        DispatchQueue.main.async {
            self.player = nil
            if self.wanted { self.start() }
        }
    }

    /// 16-bit mono PCM WAV of pure silence.
    static func silentWAV(seconds: Double, sampleRate: Int = 22050) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        let dataSize = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataSize))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))
        return d
    }
}

enum Permissions {
    static func requestMic(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
    }

    static func requestSpeech(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }
}

/// Microphone input: level metering (sound mode) and speech recognition (voice mode).
final class MicController: NSObject {
    var onLevel: ((Float) -> Void)?
    var onTranscript: (([String]) -> Void)?
    var onSegmentReset: (() -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private(set) var isRunning = false
    private var wantsSpeech = false
    private var lastLevelSent = Date.distantPast

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start(speech: Bool, locale: Locale) {
        stop()
        wantsSpeech = speech
        AudioSession.activate()

        if speech {
            recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
            recognizer?.defaultTaskHint = .dictation
            if recognizer?.isAvailable != true {
                onError?("Speech recognition isn't available for \(locale.identifier). Try Sound mode.")
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("Microphone is unavailable (another app may be using it).")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        if speech { startRecognitionTask() }

        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        isRunning = false
        task?.cancel()
        task = nil
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func startRecognitionTask() {
        guard wantsSpeech, isRunning, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if #available(iOS 16.0, *) { req.addsPunctuation = false }
        lock.lock(); request = req; lock.unlock()
        onSegmentReset?()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let words = result.bestTranscription.segments.map { $0.substring }
                DispatchQueue.main.async { self.onTranscript?(words) }
            }
            if error != nil || (result?.isFinal ?? false) {
                // Recognition sessions end after a pause or ~1 minute: start a fresh one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.isRunning, self.wantsSpeech else { return }
                    self.lock.lock(); self.request?.endAudio(); self.lock.unlock()
                    self.task = nil
                    self.startRecognitionTask()
                }
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buffer); lock.unlock()

        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))
        let now = Date()
        if now.timeIntervalSince(lastLevelSent) > 0.03 {
            lastLevelSent = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(db) }
        }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended { DispatchQueue.main.async { self.recover() } }
    }

    @objc private func configChanged() {
        DispatchQueue.main.async { self.recover() }
    }

    private func recover() {
        guard isRunning else { return }
        let speech = wantsSpeech
        let locale = recognizer?.locale ?? Locale.current
        start(speech: speech, locale: locale)
    }

    static func resolveLocale(setting: String, text: String) -> Locale {
        if setting != "auto" { return Locale(identifier: setting) }
        let supported = SFSpeechRecognizer.supportedLocales()
        var language = Locale.current.language.languageCode?.identifier ?? "en"
        if let detected = LanguageDetector.dominantLanguage(of: text) { language = detected }
        let region = Locale.current.region?.identifier
        if let region, let exact = supported.first(where: {
            $0.language.languageCode?.identifier == language && $0.region?.identifier == region
        }) { return exact }
        if let any = supported.first(where: { $0.language.languageCode?.identifier == language }) { return any }
        return Locale.current
    }
}

enum LanguageDetector {
    static func dominantLanguage(of text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        return lang.rawValue.components(separatedBy: "-").first
    }
}
