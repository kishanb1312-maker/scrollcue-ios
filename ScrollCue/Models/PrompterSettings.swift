import SwiftUI
import UIKit

// MARK: - Color

struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let yellow = RGBAColor(r: 1, g: 0.84, b: 0.2)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            color.getWhite(&w, alpha: &a)
            r = w; g = w; b = w
        }
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(uiColor) }

    func withAlpha(_ alpha: Double) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: a * alpha) }
}

extension Binding where Value == RGBAColor {
    /// Bridges a stored RGBA color to a SwiftUI ColorPicker.
    var color: Binding<Color> {
        Binding<Color>(
            get: { wrappedValue.color },
            set: { wrappedValue = RGBAColor(UIColor($0)) }
        )
    }
}

// MARK: - Enums

enum PrompterFont: String, Codable, CaseIterable, Identifiable {
    case rounded, pro, serif, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rounded: return "SF Rounded"
        case .pro: return "SF Pro"
        case .serif: return "Serif"
        case .mono: return "Monospaced"
        }
    }

    func uiFont(size: CGFloat, bold: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let design: UIFontDescriptor.SystemDesign
        switch self {
        case .rounded: design = .rounded
        case .pro: design = .default
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

enum ScrollMode: String, Codable, CaseIterable, Identifiable {
    case voice, sound, constant
    var id: String { rawValue }
    var label: String {
        switch self {
        case .voice: return "Voice"
        case .sound: return "Sound"
        case .constant: return "Constant"
        }
    }
    var detail: String {
        switch self {
        case .voice: return "Follows your speech word by word. Waits when you go off-script."
        case .sound: return "Scrolls while the mic hears you, pauses in silence. Any language."
        case .constant: return "Scrolls at a fixed speed. No microphone."
        }
    }
    var icon: String {
        switch self {
        case .voice: return "waveform.and.mic"
        case .sound: return "speaker.wave.2"
        case .constant: return "gauge.with.dots.needle.33percent"
        }
    }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum PiPShape: String, Codable, CaseIterable, Identifiable {
    case landscape, square, portrait
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Pixel size of the frames fed to the PiP window.
    var pixelSize: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1024, height: 576)
        case .square: return CGSize(width: 720, height: 720)
        case .portrait: return CGSize(width: 576, height: 1024)
        }
    }
}

enum PiPStyle: String, Codable, CaseIterable, Identifiable {
    case player, camera
    var id: String { rawValue }
    var label: String { self == .player ? "Player (⏪ ⏩ buttons)" : "Camera-friendly" }
    var detail: String {
        switch self {
        case .player: return "Video-player window with ⏪ up / ⏩ down / ⏯ buttons. iOS may pause it while the Camera app is recording."
        case .camera: return "Video-call style window that keeps running over Camera, Instagram and TikTok. No buttons: scroll with Voice, Sound, Constant or a remote."
        }
    }
}

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080, uhd4K
    var id: String { rawValue }
    var label: String { self == .hd1080 ? "1080p" : "4K" }
    var width: Int32 { self == .hd1080 ? 1920 : 3840 }
    var height: Int32 { self == .hd1080 ? 1080 : 2160 }
}

enum CameraLens: String, Codable, CaseIterable, Identifiable {
    case front, ultraWide, wide, telephoto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .front: return "Front"
        case .ultraWide: return "0.5×"
        case .wide: return "1×"
        case .telephoto: return "Tele"
        }
    }
}

enum DockItem: String, Codable, CaseIterable, Identifiable {
    case restart, sentenceBack, sentenceForward, pip, mirror, mode, video, quickSettings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .restart: return "Restart"
        case .sentenceBack: return "Previous sentence"
        case .sentenceForward: return "Next sentence"
        case .pip: return "Floating prompter (PiP)"
        case .mirror: return "Mirror"
        case .mode: return "Scroll mode"
        case .video: return "Video mode"
        case .quickSettings: return "Quick settings"
        }
    }
}

// MARK: - Settings

struct PrompterSettings: Codable, Equatable {
    // Text
    var font: PrompterFont = .rounded
    var fontSize: Double = 42
    var bold: Bool = true
    var textColor: RGBAColor = .white
    var backgroundColor: RGBAColor = .black
    var highlightColor: RGBAColor = .yellow
    var lineSpacing: Double = 8
    var paragraphSpacing: Double = 28
    var horizontalMargin: Double = 24
    var alignment: TextAlign = .left
    var rightToLeft: Bool = false
    var textOpacity: Double = 1
    var backgroundOpacity: Double = 1

    // Reading aids
    var activeLinePosition: Double = 0.3
    var showActiveLineMarker: Bool = true
    var highlightCurrentWord: Bool = true
    var dimReadText: Bool = true

    // Mirroring
    var mirrorHorizontal: Bool = false
    var mirrorVertical: Bool = false

    // Scrolling
    var scrollMode: ScrollMode = .voice
    var constantSpeed: Double = 40      // points per second at 40pt text
    var soundSpeed: Double = 45
    var soundThreshold: Double = -38    // dBFS
    var soundHangTime: Double = 0.6     // keep scrolling this long after sound stops
    var countdownSeconds: Int = 3
    var tapToJump: Bool = true

    // Voice
    var speechLocale: String = "auto"
    var voiceCommandsEnabled: Bool = true
    var commandNext: String = "go next"
    var commandBack: String = "go back"
    var commandStart: String = "go to start"
    var commandFinish: String = "go to finish"
    var commandNextSentence: String = "next sentence"
    var commandPreviousSentence: String = "previous sentence"
    var commandMirror: String = "mirror screen"

    // Picture in Picture
    var pipStyle: PiPStyle = .player
    var pipShape: PiPShape = .landscape
    var pipFontSize: Double = 30
    var pipMargin: Double = 16
    var pipRotation: Int = 0            // 0, 90, 180, 270
    var pipShowMicIndicator: Bool = true
    var pipOpacity: Double = 1
    var pipMirror: Bool = false
    var pipStepLines: Int = 2
    var pipActiveLinePosition: Double = 0.3
    var pipAutoStart: Bool = true

    // Recording
    var videoResolution: VideoResolution = .hd1080
    var videoFPS: Int = 30
    var videoHDR: Bool = false
    var cameraLens: CameraLens = .front
    var overlayHeight: Double = 0.38
    var overlayOpacity: Double = 0.75

    // Dock
    var dockItems: [DockItem] = DockItem.allCases.filter { $0 != .mode }

    // Library
    var showDemoScript: Bool = true

    // MARK: Derived

    func font(scale: Double = 1) -> UIFont { font.uiFont(size: CGFloat(fontSize * scale), bold: bold) }

    /// Robust decoding: missing keys (from older versions) fall back to defaults.
    static func decode(from data: Data) -> PrompterSettings? {
        guard
            let defaults = try? JSONEncoder().encode(PrompterSettings()),
            var base = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any],
            let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for (k, v) in saved { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        if let s = try? JSONDecoder().decode(PrompterSettings.self, from: merged) { return s }
        // A single bad key shouldn't wipe everything: retry key by key.
        var result = PrompterSettings()
        for (k, v) in saved {
            var attempt = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(result))) as? [String: Any] ?? [:]
            attempt[k] = v
            if let d = try? JSONSerialization.data(withJSONObject: attempt),
               let s = try? JSONDecoder().decode(PrompterSettings.self, from: d) {
                result = s
            }
        }
        return result
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: PrompterSettings
}
