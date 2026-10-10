import SwiftUI

/// Loads a script and hands it to the prompter screen.
struct PrompterView: View {
    let scriptID: UUID
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let script = scripts.script(id: scriptID) {
            PrompterScreen(script: script, settings: settingsStore.settings)
        } else {
            VStack(spacing: 16) {
                Text("Script not found")
                Button("Close") { dismiss() }
            }
        }
    }
}

struct PrompterScreen: View {
    let script: Script
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var stats: StatsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var engine: PrompterEngine
    @StateObject private var pip = PiPManager()
    @StateObject private var camera = CameraController()

    @State private var showQuickSettings = false
    @State private var videoMode = false
    @State private var dockAwake = Date()
    @State private var now = Date()

    init(script: Script, settings: PrompterSettings) {
        self.script = script
        let start = script.lastWordIndex < ScriptTokens(text: script.body).count - 1 ? script.lastWordIndex : 0
        _engine = StateObject(wrappedValue: PrompterEngine(text: script.body, settings: settings, startWord: start))
    }

    private var settings: PrompterSettings { settingsStore.settings }

    var body: some View {
        ZStack {
            settings.backgroundColor.color.ignoresSafeArea()

            // The PiP layer must live in the view hierarchy; it's hidden behind the canvas.
            PiPHostView(manager: pip)
                .ignoresSafeArea()

            if videoMode {
                CameraPrompterView(engine: engine, camera: camera, remote: remoteActions, close: { withAnimation { videoMode = false } })
                    .transition(.move(edge: .trailing))
            } else {
                PrompterCanvas(engine: engine, settings: settings, remote: remoteActions)
                    .ignoresSafeArea(edges: .horizontal)
                    .padding(.top, 52)
                    .padding(.bottom, 84)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    dock
                }
            }

            if let c = engine.countdown {
                Text("\(c)")
                    .font(.system(size: 140, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(40)
                    .background(.black.opacity(0.55), in: Circle())
                    .transition(.scale.combined(with: .opacity))
                    .id(c)
            }

            if let msg = engine.statusMessage ?? pip.lastError {
                VStack {
                    Toast(text: msg) {
                        engine.statusMessage = nil
                        pip.lastError = nil
                    }
                    .padding(.top, 60)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: engine.countdown)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showQuickSettings) {
            QuickSettingsView()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
        .onChange(of: settingsStore.settings) { _, new in
            engine.update(settings: new)
            pip.settings = new
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scripts.savePosition(script.id, wordIndex: engine.cursor) }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.headline)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(script.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: engine.progress).tint(settings.highlightColor.color)
            }
            if engine.micActive {
                MicMeter(level: engine.micLevel, active: engine.isHearingSound || settings.scrollMode == .voice)
            }
            if engine.sessionWords > 0 {
                Text("\(engine.sessionWords)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Menu {
                Picker("Scroll mode", selection: $settingsStore.settings.scrollMode) {
                    ForEach(ScrollMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
            } label: {
                Label(settings.scrollMode.label, systemImage: settings.scrollMode.icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 6)
        .frame(height: 52)
        .background(.black.opacity(0.35))
    }

    private var dockFaded: Bool { engine.isPlaying && now.timeIntervalSince(dockAwake) > 3 }

    private var dock: some View {
        let items = settings.dockItems
        let leftSet: [DockItem] = [.restart, .sentenceBack]
        let left = items.filter { leftSet.contains($0) }
        let right = items.filter { !leftSet.contains($0) }
        return HStack(spacing: 2) {
            ForEach(left) { dockButton($0) }
            Spacer(minLength: 0)
            Button {
                dockAwake = Date()
                engine.togglePlay()
            } label: {
                Image(systemName: engine.isPlaying || engine.countdown != nil ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 58, height: 58)
                    .background(settings.highlightColor.color, in: Circle())
            }
            Spacer(minLength: 0)
            ForEach(right) { dockButton($0) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background(.black.opacity(0.35))
        .opacity(dockFaded ? 0.3 : 1)
        .animation(.easeInOut, value: dockFaded)
        .simultaneousGesture(TapGesture().onEnded { dockAwake = Date() })
    }

    @ViewBuilder
    private func dockButton(_ item: DockItem) -> some View {
        Button {
            dockAwake = Date()
            handle(item)
        } label: {
            Image(systemName: icon(for: item))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn(item) ? settings.highlightColor.color : .white)
                .frame(minWidth: 26, maxWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(item.label)
    }

    private func icon(for item: DockItem) -> String {
        switch item {
        case .restart: return "backward.end.fill"
        case .sentenceBack: return "chevron.up"
        case .sentenceForward: return "chevron.down"
        case .pip: return pip.isActive ? "pip.exit" : "pip.enter"
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .mode: return settings.scrollMode.icon
        case .video: return "video.fill"
        case .quickSettings: return "textformat.size"
        }
    }

    private func isOn(_ item: DockItem) -> Bool {
        switch item {
        case .pip: return pip.isActive
        case .mirror: return settings.mirrorHorizontal
        default: return false
        }
    }

    private func handle(_ item: DockItem) {
        switch item {
        case .restart: engine.restart()
        case .sentenceBack: engine.previousSentence()
        case .sentenceForward: engine.nextSentence()
        case .pip: pip.toggle()
        case .mirror: settingsStore.settings.mirrorHorizontal.toggle()
        case .mode:
            let all = ScrollMode.allCases
            let i = all.firstIndex(of: settings.scrollMode) ?? 0
            settingsStore.settings.scrollMode = all[(i + 1) % all.count]
        case .video: withAnimation { videoMode = true }
        case .quickSettings: showQuickSettings = true
        }
    }

    private var remoteActions: RemoteActions {
        RemoteActions(
            toggleRecord: { if videoMode { camera.toggleRecording() } else { withAnimation { videoMode = true } } },
            toggleMirror: { settingsStore.settings.mirrorHorizontal.toggle() },
            speedUp: { adjustSpeed(+5) },
            speedDown: { adjustSpeed(-5) }
        )
    }

    private func adjustSpeed(_ d: Double) {
        if settings.scrollMode == .sound {
            settingsStore.settings.soundSpeed = min(max(settings.soundSpeed + d, 5), 200)
        } else {
            settingsStore.settings.constantSpeed = min(max(settings.constantSpeed + d, 5), 200)
        }
    }

    // MARK: Lifecycle

    private func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        AudioSession.activate()
        pip.settings = settings
        pip.attach(engine: engine)
        engine.onWordsSpoken = { [weak stats] n in stats?.addWords(n) }
        engine.onSessionEnded = { [weak stats] secs in stats?.addSession(seconds: secs) }
        engine.onMirrorCommand = { settingsStore.settings.mirrorHorizontal.toggle() }
        if LaunchArgs.quick { showQuickSettings = true }
        if LaunchArgs.video { videoMode = true }
        if LaunchArgs.mirror { settingsStore.settings.mirrorHorizontal = true }
        if LaunchArgs.unmirror { settingsStore.settings.mirrorHorizontal = false }
        if LaunchArgs.autoplay {
            settingsStore.settings.scrollMode = .constant
            settingsStore.settings.constantSpeed = 80
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.play(skipCountdown: true) }
        }
    }

    private func teardown() {
        UIApplication.shared.isIdleTimerDisabled = false
        scripts.savePosition(script.id, wordIndex: engine.cursor >= engine.tokens.count - 1 ? 0 : engine.cursor)
        engine.pause()
        pip.stop()
        camera.stopSession()
        KeepAlive.shared.stop()
    }
}

struct MicMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        let norm = CGFloat(min(max((level + 60) / 60, 0), 1))
        HStack(spacing: 4) {
            Image(systemName: "mic.fill").font(.caption)
                .foregroundStyle(active ? .green : .secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(active ? Color.green : Color.gray).frame(width: g.size.width * norm)
                }
            }
            .frame(width: 34, height: 5)
        }
        .animation(.linear(duration: 0.05), value: norm)
    }
}

struct Toast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            Text(text).font(.footnote).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.bold()) }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            dismiss()
        }
    }
}
