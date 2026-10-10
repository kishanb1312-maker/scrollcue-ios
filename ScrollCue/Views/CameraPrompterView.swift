import SwiftUI
import AVFoundation
import AVKit

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = .resizeAspectFill
        camera.previewLayer = v.previewLayer
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}

/// Video mode: camera preview with the prompter overlaid right under the lens.
struct CameraPrompterView: View {
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var camera: CameraController
    var remote: RemoteActions
    let close: () -> Void

    @EnvironmentObject var settingsStore: SettingsStore
    @State private var showOptions = false
    @State private var reviewTake: URL?
    @State private var now = Date()
    @GestureState private var resizing: CGFloat = 0

    private var s: PrompterSettings { settingsStore.settings }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                CameraPreview(camera: camera)
                    .ignoresSafeArea()

                // Prompter overlay, pinned to the top (closest to the front camera).
                VStack(spacing: 0) {
                    PrompterCanvas(engine: engine, settings: s, backgroundAlpha: CGFloat(s.overlayOpacity), remote: remote)
                        .frame(height: max(120, geo.size.height * CGFloat(s.overlayHeight) + resizing))
                    // Drag handle to resize the overlay.
                    Capsule().fill(.white.opacity(0.6)).frame(width: 44, height: 5)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture()
                            .updating($resizing) { v, state, _ in state = v.translation.height }
                            .onEnded { v in
                                let h = geo.size.height * CGFloat(s.overlayHeight) + v.translation.height
                                settingsStore.settings.overlayHeight = Double(min(max(h / geo.size.height, 0.15), 0.85))
                            })
                    Spacer()
                }

                VStack {
                    Spacer()
                    controls
                }
            }
        }
        .onAppear(perform: startCamera)
        .onChange(of: s.cameraLens) { _, _ in startCamera() }
        .onChange(of: s.videoResolution) { _, _ in startCamera() }
        .onChange(of: s.videoFPS) { _, _ in startCamera() }
        .onChange(of: s.videoHDR) { _, _ in startCamera() }
        .onChange(of: camera.lastTake) { _, url in
            if let url { reviewTake = url }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now = $0 }
        .sheet(isPresented: $showOptions) {
            CameraOptionsView(hdrAvailable: camera.hdrAvailable, lenses: camera.availableLenses)
                .presentationDetents([.medium])
        }
        .sheet(item: $reviewTake) { url in
            TakeReviewView(url: url) {
                reviewTake = nil
                camera.lastTake = nil
            }
            .interactiveDismissDisabled()
        }
        .alert("Camera", isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.error ?? "")
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let started = camera.recordingStarted {
                Text(Self.format(now.timeIntervalSince(started)))
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.red, in: Capsule())
            }
            // Lens picker
            HStack(spacing: 8) {
                ForEach(camera.availableLenses) { lens in
                    Button(lens.label) { settingsStore.settings.cameraLens = lens }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(s.cameraLens == lens ? Color.yellow : Color.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(s.cameraLens == lens ? .black : .white)
                        .disabled(camera.isRecording)
                }
            }
            HStack {
                Button(action: close) {
                    circleIcon("text.alignleft")
                }
                .disabled(camera.isRecording)
                Spacer()
                Button { engine.togglePlay() } label: {
                    circleIcon(engine.isPlaying || engine.countdown != nil ? "pause.fill" : "play.fill")
                }
                Spacer()
                Button {
                    if camera.isRecording {
                        camera.stopRecording()
                        engine.pause()
                    } else {
                        camera.startRecording()
                        if !engine.isPlaying { engine.play() }
                    }
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                            .fill(.red)
                            .frame(width: camera.isRecording ? 30 : 60, height: camera.isRecording ? 30 : 60)
                    }
                    .animation(.spring(duration: 0.25), value: camera.isRecording)
                }
                Spacer()
                Button { engine.restart() } label: { circleIcon("backward.end.fill") }
                Spacer()
                Button { showOptions = true } label: { circleIcon("gearshape.fill") }
                    .disabled(camera.isRecording)
            }
            .padding(.horizontal, 20)
            Text("\(s.videoResolution.label) · \(s.videoFPS) fps\(s.videoHDR ? " · HDR" : "")")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.5), in: Circle())
    }

    private func startCamera() {
        camera.requestAccessAndStart(lens: s.cameraLens, resolution: s.videoResolution, fps: s.videoFPS, hdr: s.videoHDR)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct CameraOptionsView: View {
    let hdrAvailable: Bool
    let lenses: [CameraLens]
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                RecordingSettingsSection(settings: $settingsStore.settings, hdrAvailable: hdrAvailable, lenses: lenses)
            }
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct TakeReviewView: View {
    let url: URL
    let done: () -> Void
    @State private var player: AVPlayer
    @State private var saving = false
    @State private var message: String?

    init(url: URL, done: @escaping () -> Void) {
        self.url = url
        self.done = done
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        player.pause()
                        try? FileManager.default.removeItem(at: url)
                        done()
                    } label: {
                        Label("Discard", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        player.pause()
                        saving = true
                        CameraController.saveToPhotos(url) { ok, err in
                            saving = false
                            if ok { done() } else { message = err ?? "Couldn't save. The take is kept under Settings › Recordings." }
                        }
                    } label: {
                        Label(saving ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                }
                Button("Keep for later") { player.pause(); done() }
                    .font(.footnote)
            }
            .padding()
            .navigationTitle("Review take")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
