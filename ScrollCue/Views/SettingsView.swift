import SwiftUI
import Speech
import AVKit

// MARK: - Reusable controls

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Sections

struct TextSettingsSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section("Text") {
            Picker("Font", selection: $settings.font) {
                ForEach(PrompterFont.allCases) { f in
                    Text(f.label).font(Font(f.uiFont(size: 17, bold: false))).tag(f)
                }
            }
            Toggle("Bold", isOn: $settings.bold)
            SliderRow(title: "Font size", value: $settings.fontSize, range: 16...160, format: { "\(Int($0)) pt" })
            SliderRow(title: "Line spacing", value: $settings.lineSpacing, range: 0...60)
            SliderRow(title: "Paragraph spacing", value: $settings.paragraphSpacing, range: 0...120)
            SliderRow(title: "Side margins", value: $settings.horizontalMargin, range: 0...160)
            Picker("Alignment", selection: $settings.alignment) {
                ForEach(TextAlign.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Text direction", selection: $settings.rightToLeft) {
                Text("Left to right").tag(false)
                Text("Right to left").tag(true)
            }
        }
        Section("Colors") {
            ColorPicker("Text", selection: $settings.textColor.color, supportsOpacity: false)
            ColorPicker("Background", selection: $settings.backgroundColor.color, supportsOpacity: false)
            ColorPicker("Highlight", selection: $settings.highlightColor.color, supportsOpacity: false)
            SliderRow(title: "Text opacity", value: $settings.textOpacity, range: 0.1...1, step: 0.05, format: percent)
            SliderRow(title: "Background opacity", value: $settings.backgroundOpacity, range: 0...1, step: 0.05, format: percent)
            HStack(spacing: 8) {
                ForEach(Array(Self.themes.enumerated()), id: \.offset) { _, t in
                    Button {
                        settings.textColor = t.0; settings.backgroundColor = t.1
                    } label: {
                        Text("Aa").font(.headline)
                            .foregroundStyle(t.0.color)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(t.1.color, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static let themes: [(RGBAColor, RGBAColor)] = [
        (.white, .black),
        (.black, .white),
        (.yellow, .black),
        (RGBAColor(r: 0.4, g: 1, b: 0.55), .black),
        (.white, RGBAColor(r: 0.1, g: 0.14, b: 0.3)),
    ]
}

struct ReadingAidsSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section("Reading") {
            SliderRow(title: "Active line position", value: $settings.activeLinePosition, range: 0.05...0.8, step: 0.01, format: percent)
            Toggle("Show active line marker", isOn: $settings.showActiveLineMarker)
            Toggle("Highlight current word", isOn: $settings.highlightCurrentWord)
            Toggle("Dim text already read", isOn: $settings.dimReadText)
            Toggle("Tap a word to jump to it", isOn: $settings.tapToJump)
            Stepper("Countdown: \(settings.countdownSeconds == 0 ? "Off" : "\(settings.countdownSeconds)s")",
                    value: $settings.countdownSeconds, in: 0...10)
        }
    }
}

struct MirrorSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section {
            Toggle("Mirror horizontally", isOn: $settings.mirrorHorizontal)
            Toggle("Flip vertically", isOn: $settings.mirrorVertical)
        } header: {
            Text("Mirroring")
        } footer: {
            Text("For beam-splitter teleprompter rigs (Elgato, Neewer, Glide Gear, Desview…).")
        }
    }
}

struct ScrollSettingsSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section {
            Picker("Scroll mode", selection: $settings.scrollMode) {
                ForEach(ScrollMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(settings.scrollMode.detail).font(.footnote).foregroundStyle(.secondary)
            switch settings.scrollMode {
            case .constant:
                SliderRow(title: "Speed", value: $settings.constantSpeed, range: 5...200)
            case .sound:
                SliderRow(title: "Speed while talking", value: $settings.soundSpeed, range: 5...200)
                SliderRow(title: "Sensitivity threshold", value: $settings.soundThreshold, range: -70...(-10), format: { "\(Int($0)) dB" })
                SliderRow(title: "Keep scrolling after silence", value: $settings.soundHangTime, range: 0...2, step: 0.1, format: { String(format: "%.1fs", $0) })
            case .voice:
                EmptyView()
            }
        } header: {
            Text("Scrolling")
        }
    }
}

struct VoiceSettingsSection: View {
    @Binding var settings: PrompterSettings
    @State private var locales: [Locale] = []

    var body: some View {
        Section {
            Picker("Language", selection: $settings.speechLocale) {
                Text("Auto-detect from script").tag("auto")
                ForEach(locales, id: \.identifier) { l in
                    Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                }
            }
            .onAppear {
                if locales.isEmpty {
                    locales = SFSpeechRecognizer.supportedLocales().sorted {
                        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") <
                        (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "")
                    }
                }
            }
            Toggle("Voice commands", isOn: $settings.voiceCommandsEnabled)
            if settings.voiceCommandsEnabled {
                CommandField(title: "Next sentence", text: $settings.commandNextSentence)
                CommandField(title: "Previous sentence", text: $settings.commandPreviousSentence)
                CommandField(title: "Go next", text: $settings.commandNext)
                CommandField(title: "Go back", text: $settings.commandBack)
                CommandField(title: "Go to start", text: $settings.commandStart)
                CommandField(title: "Go to finish", text: $settings.commandFinish)
                CommandField(title: "Toggle mirror", text: $settings.commandMirror)
            }
        } header: {
            Text("Voice")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Label(onDeviceText, systemImage: onDevice ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(onDevice ? .green : .orange)
                Text("Commands work in Voice mode while the prompter is playing. If on-device recognition isn't available, enable Dictation in iOS Settings › General › Keyboard and download the language.")
            }
        }
    }
}

extension VoiceSettingsSection {
    private var resolvedLocale: Locale {
        settings.speechLocale == "auto" ? Locale.current : Locale(identifier: settings.speechLocale)
    }
    var onDevice: Bool { SFSpeechRecognizer(locale: resolvedLocale)?.supportsOnDeviceRecognition ?? false }
    var onDeviceText: String {
        let name = Locale.current.localizedString(forIdentifier: resolvedLocale.identifier) ?? resolvedLocale.identifier
        return onDevice ? "On-device recognition available for \(name). Works offline, nothing leaves the phone."
                        : "On-device recognition isn't available for \(name); Apple's servers may be used."
    }
}

private struct CommandField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

struct PiPSettingsSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section {
            Picker("Window shape", selection: $settings.pipShape) {
                ForEach(PiPShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            SliderRow(title: "Font size", value: $settings.pipFontSize, range: 12...90, format: { "\(Int($0)) pt" })
            SliderRow(title: "Margins", value: $settings.pipMargin, range: 0...80)
            SliderRow(title: "Active line position", value: $settings.pipActiveLinePosition, range: 0.05...0.8, step: 0.01, format: percent)
            Picker("Rotate content", selection: $settings.pipRotation) {
                Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
            }
            .pickerStyle(.segmented)
            Stepper("Up/down buttons move \(settings.pipStepLines) line\(settings.pipStepLines == 1 ? "" : "s")",
                    value: $settings.pipStepLines, in: 1...10)
            SliderRow(title: "Prompt opacity", value: $settings.pipOpacity, range: 0...1, step: 0.05, format: percent)
            Toggle("Microphone indicator", isOn: $settings.pipShowMicIndicator)
            Toggle("Mirror horizontally", isOn: $settings.pipMirror)
            Toggle("Start automatically when leaving the app", isOn: $settings.pipAutoStart)
        } header: {
            Text("Floating prompter (PiP)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tap the floating window once to show its controls. ⏪ scrolls UP, ⏩ scrolls DOWN, ⏯ plays and pauses. iOS doesn't let apps receive finger swipes inside a PiP window, so these buttons (plus voice, sound scrolling or a Bluetooth remote) are how you steer it.")
                if let diag = PiPDiagnostics.lastSummary {
                    Text("Last PiP session: \(diag)").font(.caption2.monospaced())
                }
            }
        }
    }
}

struct RecordingSettingsSection: View {
    @Binding var settings: PrompterSettings
    var hdrAvailable: Bool = true
    var lenses: [CameraLens] = CameraLens.allCases

    var body: some View {
        Section {
            Picker("Camera", selection: $settings.cameraLens) {
                ForEach(lenses) { Text($0.label).tag($0) }
            }
            Picker("Resolution", selection: $settings.videoResolution) {
                ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $settings.videoFPS) {
                Text("24").tag(24); Text("25").tag(25); Text("30").tag(30)
            }
            .pickerStyle(.segmented)
            Toggle("10-bit HDR (HLG)", isOn: $settings.videoHDR)
                .disabled(!hdrAvailable)
            SliderRow(title: "Prompter overlay height", value: $settings.overlayHeight, range: 0.15...0.85, step: 0.01, format: percent)
            SliderRow(title: "Overlay background", value: $settings.overlayOpacity, range: 0...1, step: 0.05, format: percent)
        } header: {
            Text("Video recording")
        }
    }
}

struct DockSettingsSection: View {
    @Binding var settings: PrompterSettings

    var body: some View {
        Section {
            ForEach(DockItem.allCases) { item in
                Toggle(item.label, isOn: Binding(
                    get: { settings.dockItems.contains(item) },
                    set: { on in
                        if on { settings.dockItems = DockItem.allCases.filter { settings.dockItems.contains($0) || $0 == item } }
                        else { settings.dockItems.removeAll { $0 == item } }
                    }))
            }
        } header: {
            Text("Dock buttons")
        }
    }
}

// MARK: - Screens

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { PresetsView() } label: { Label("Presets", systemImage: "square.stack.3d.up") }
                    NavigationLink { TakesView() } label: { Label("Recordings", systemImage: "film.stack") }
                    NavigationLink { RemoteHelpView() } label: { Label("Keyboard & remote", systemImage: "keyboard") }
                }
                ScrollSettingsSection(settings: $store.settings)
                TextSettingsSection(settings: $store.settings)
                ReadingAidsSection(settings: $store.settings)
                MirrorSection(settings: $store.settings)
                PiPSettingsSection(settings: $store.settings)
                VoiceSettingsSection(settings: $store.settings)
                RecordingSettingsSection(settings: $store.settings)
                DockSettingsSection(settings: $store.settings)
                Section("Library") {
                    Toggle("Show demo script", isOn: $store.settings.showDemoScript)
                }
                Section {
                    Button("Reset all settings", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("ScrollCue \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · built for personal use.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.resetToDefaults() }
            }
        }
    }
}

/// Compact settings shown over the prompter.
struct QuickSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(store.presets) { p in
                                Button(p.name) { store.apply(p) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Section("Quick") {
                    Picker("Mode", selection: $store.settings.scrollMode) {
                        ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if store.settings.scrollMode == .constant {
                        SliderRow(title: "Speed", value: $store.settings.constantSpeed, range: 5...200)
                    } else if store.settings.scrollMode == .sound {
                        SliderRow(title: "Speed while talking", value: $store.settings.soundSpeed, range: 5...200)
                        SliderRow(title: "Threshold", value: $store.settings.soundThreshold, range: -70...(-10), format: { "\(Int($0)) dB" })
                    }
                    SliderRow(title: "Font size", value: $store.settings.fontSize, range: 16...160, format: { "\(Int($0)) pt" })
                    SliderRow(title: "Side margins", value: $store.settings.horizontalMargin, range: 0...160)
                    SliderRow(title: "Line spacing", value: $store.settings.lineSpacing, range: 0...60)
                    SliderRow(title: "Active line", value: $store.settings.activeLinePosition, range: 0.05...0.8, step: 0.01, format: percent)
                    SliderRow(title: "Text opacity", value: $store.settings.textOpacity, range: 0.1...1, step: 0.05, format: percent)
                    Toggle("Mirror", isOn: $store.settings.mirrorHorizontal)
                    Toggle("Highlight current word", isOn: $store.settings.highlightCurrentWord)
                }
                PiPSettingsSection(settings: $store.settings)
                TextSettingsSection(settings: $store.settings)
            }
            .navigationTitle("Quick settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PresetsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        List {
            Section {
                Button { name = ""; naming = true } label: { Label("Save current setup as preset", systemImage: "plus") }
            }
            Section {
                ForEach(store.presets) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name).font(.headline)
                            Text("\(p.settings.scrollMode.label) · \(Int(p.settings.fontSize)) pt · \(p.settings.font.label)\(p.settings.mirrorHorizontal ? " · mirrored" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { store.apply(p) }.buttonStyle(.borderedProminent)
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.presets.removeAll { $0.id == p.id } } label: { Label("Delete", systemImage: "trash") }
                        Button { store.overwrite(p) } label: { Label("Update", systemImage: "arrow.triangle.2.circlepath") }.tint(.orange)
                    }
                }
                .onMove { store.presets.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Swipe a preset to update it with your current settings or delete it.")
            }
        }
        .navigationTitle("Presets")
        .toolbar { EditButton() }
        .alert("New preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { store.saveCurrentAsPreset(named: name) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct TakesView: View {
    @State private var takes: [URL] = []
    @State private var playing: URL?
    @State private var message: String?

    var body: some View {
        List {
            if takes.isEmpty {
                Text("No leftover recordings. Takes you keep for later show up here.").foregroundStyle(.secondary)
            }
            ForEach(takes, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(url.deletingPathExtension().lastPathComponent).font(.subheadline)
                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { playing = url } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: url); reload()
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        CameraController.saveToPhotos(url) { ok, err in
                            message = ok ? "Saved to Photos." : (err ?? "Couldn't save.")
                            reload()
                        }
                    } label: { Label("Save", systemImage: "square.and.arrow.down") }.tint(.green)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Recordings")
        .onAppear(perform: reload)
        .sheet(item: $playing) { url in
            VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
        }
    }

    private func reload() { takes = CameraController.leftoverTakes() }
}

struct RemoteHelpView: View {
    var body: some View {
        List {
            Section {
                row("Space / Enter", "Play / pause")
                row("↑ / ↓", "Scroll one line up / down")
                row("Page Up / Page Down", "Scroll four lines")
                row("← / →", "Previous / next sentence")
                row("Home / End or S", "Go to start / end")
                row("+ / −", "Faster / slower")
                row("M", "Toggle mirror")
                row("R", "Start / stop recording (video mode)")
            } footer: {
                Text("Works with Bluetooth keyboards and most page-turner remotes while ScrollCue is in front. Over other apps (PiP), use the floating window's buttons or voice.")
            }
        }
        .navigationTitle("Keyboard & remote")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.body.monospaced()); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}

struct StatsView: View {
    @EnvironmentObject var stats: StatsStore
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    stat("Words spoken", stats.lifetimeWords.formatted())
                    stat("Sessions", stats.sessions.formatted())
                    stat("Time prompting", Self.duration(stats.lifetimeSeconds))
                }
                Section("Milestones") {
                    ForEach(StatsStore.milestones, id: \.self) { m in
                        HStack {
                            Image(systemName: stats.lifetimeWords >= m ? "checkmark.seal.fill" : "seal")
                                .foregroundStyle(stats.lifetimeWords >= m ? .yellow : .secondary)
                            Text("\(m.formatted()) words")
                            Spacer()
                            if stats.lifetimeWords < m {
                                Text("\((m - stats.lifetimeWords).formatted()) to go").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Reset stats", role: .destructive) { confirm = true }
                }
            }
            .navigationTitle("Stats")
            .confirmationDialog("Reset all stats?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { stats.reset() }
            }
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).font(.title3.weight(.semibold).monospacedDigit()) }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s) / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}
