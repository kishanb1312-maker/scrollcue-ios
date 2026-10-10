import Foundation
import SwiftUI

enum Storage {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScrollCue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var takesDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Settings + presets

final class SettingsStore: ObservableObject {
    @Published var settings: PrompterSettings { didSet { if settings != oldValue { save() } } }
    @Published var presets: [Preset] { didSet { savePresets() } }

    private let settingsKey = "scrollcue.settings.v1"
    private let presetsKey = "scrollcue.presets.v1"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: settingsKey), let s = PrompterSettings.decode(from: data) {
            settings = s
        } else {
            settings = PrompterSettings()
        }
        if let data = defaults.data(forKey: presetsKey),
           let p = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = p
        } else {
            presets = [
                Preset(name: "Default", settings: PrompterSettings()),
                Preset(name: "Beam splitter", settings: {
                    var s = PrompterSettings(); s.mirrorHorizontal = true; s.pipMirror = true; s.fontSize = 56; return s
                }()),
                Preset(name: "Big & slow", settings: {
                    var s = PrompterSettings(); s.fontSize = 64; s.constantSpeed = 28; s.scrollMode = .constant; return s
                }()),
            ]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        presets.append(Preset(name: trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed, settings: settings))
    }

    func apply(_ preset: Preset) {
        // Keep the dock layout the user is used to; presets are about the look and scrolling.
        var s = preset.settings
        s.dockItems = settings.dockItems
        settings = s
    }

    func overwrite(_ preset: Preset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].settings = settings
    }

    func resetToDefaults() { settings = PrompterSettings() }
}

// MARK: - Scripts

struct Script: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var createdAt = Date()
    var updatedAt = Date()
    var lastWordIndex: Int = 0
    var lastEditedOn: String = DeviceInfo.name
    var isDemo: Bool = false

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled script" : String(trimmed.prefix(60))
    }

    var wordCount: Int { body.split(whereSeparator: { $0.isWhitespace }).count }

    /// Approximate read time at 150 words per minute.
    var readTime: String {
        let seconds = Int((Double(wordCount) / 150.0 * 60).rounded())
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

enum DeviceInfo {
    static let name: String = ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : "iPhone"
}

final class ScriptStore: ObservableObject {
    static let maxScripts = 100

    @Published private(set) var scripts: [Script] = []

    private var fileURL: URL { Storage.directory.appendingPathComponent("scripts.json") }

    init() {
        load()
        if scripts.isEmpty && !UserDefaults.standard.bool(forKey: "scrollcue.demoSeeded") {
            scripts = [Script(title: "Welcome to ScrollCue", body: DemoScript.text, isDemo: true)]
            UserDefaults.standard.set(true, forKey: "scrollcue.demoSeeded")
            persist()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Script].self, from: data) else { return }
        scripts = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        let snapshot = scripts
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @discardableResult
    func create(title: String = "", body: String = "") -> Script {
        let script = Script(title: title, body: body)
        scripts.insert(script, at: 0)
        trim()
        persist()
        return script
    }

    func update(_ script: Script, touch: Bool = true) {
        guard let i = scripts.firstIndex(where: { $0.id == script.id }) else {
            scripts.insert(script, at: 0); trim(); persist(); return
        }
        var s = script
        if touch {
            s.updatedAt = Date()
            s.lastEditedOn = DeviceInfo.name
        }
        scripts[i] = s
        if touch { scripts.sort { $0.updatedAt > $1.updatedAt } }
        persist()
    }

    func savePosition(_ id: UUID, wordIndex: Int) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].lastWordIndex = wordIndex
        persist()
    }

    func duplicate(_ script: Script) {
        var copy = Script(title: script.displayTitle + " copy", body: script.body)
        copy.lastWordIndex = 0
        scripts.insert(copy, at: 0)
        trim()
        persist()
    }

    func delete(_ ids: [UUID]) {
        scripts.removeAll { ids.contains($0.id) }
        persist()
    }

    func script(id: UUID) -> Script? { scripts.first { $0.id == id } }

    private func trim() {
        if scripts.count > Self.maxScripts { scripts = Array(scripts.prefix(Self.maxScripts)) }
    }
}

// MARK: - Stats

final class StatsStore: ObservableObject {
    @Published private(set) var lifetimeWords: Int
    @Published private(set) var sessions: Int
    @Published private(set) var lifetimeSeconds: Double
    @Published var milestone: Int?

    static let milestones = [100, 500, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]

    private let d = UserDefaults.standard

    init() {
        lifetimeWords = d.integer(forKey: "stats.words")
        sessions = d.integer(forKey: "stats.sessions")
        lifetimeSeconds = d.double(forKey: "stats.seconds")
    }

    func addWords(_ n: Int) {
        guard n > 0 else { return }
        let before = lifetimeWords
        lifetimeWords += n
        d.set(lifetimeWords, forKey: "stats.words")
        if let m = Self.milestones.first(where: { before < $0 && lifetimeWords >= $0 }) {
            milestone = m
        }
    }

    func addSession(seconds: Double) {
        sessions += 1
        lifetimeSeconds += seconds
        d.set(sessions, forKey: "stats.sessions")
        d.set(lifetimeSeconds, forKey: "stats.seconds")
    }

    func reset() {
        lifetimeWords = 0; sessions = 0; lifetimeSeconds = 0
        d.set(0, forKey: "stats.words"); d.set(0, forKey: "stats.sessions"); d.set(0.0, forKey: "stats.seconds")
    }
}
