import SwiftUI
import AVFoundation
import Speech

/// First-launch walkthrough: what ScrollCue does, how the PiP buttons scroll,
/// and the permissions it needs.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0
    @State private var mic: Bool? = nil
    @State private var speech: Bool? = nil
    @State private var camera: Bool? = nil

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                pip.tag(1)
                permissions.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < 2 { withAnimation { page += 1 } } else { finish() }
            } label: {
                Text(page < 2 ? "Continue" : "Start using ScrollCue")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.yellow)
            Text("ScrollCue").font(.largeTitle.bold())
            Text("Your teleprompter that listens. Read out loud and the script follows your voice, word by word.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
    }

    private var pip: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Float it over any app").font(.title.bold())
            // Mock of the PiP window and its controls.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("your script floats").foregroundStyle(.white.opacity(0.4))
                    Text("over the camera,").foregroundStyle(.yellow)
                    Text("and it stays off camera.")
                }
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                HStack(spacing: 34) {
                    controlIcon("gobackward.15", "Scroll up")
                    controlIcon("pause.fill", "Play / pause")
                    controlIcon("goforward.15", "Scroll down")
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.08))
            }
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
            Text("Tap the PiP button in the prompter, then open your camera app. Tap the floating window once to show its controls: the left skip button scrolls **up** and the right one scrolls **down**.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    private func controlIcon(_ name: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: name).font(.title2)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Permissions").font(.title.bold())
            Text("Everything stays on your iPhone.").foregroundStyle(.secondary)
            permissionRow("mic.fill", "Microphone", "Voice and sound scrolling", state: mic) {
                Permissions.requestMic { mic = $0 }
            }
            permissionRow("waveform", "Speech recognition", "Follows your words, on-device", state: speech) {
                Permissions.requestSpeech { speech = $0 }
            }
            permissionRow("video.fill", "Camera", "Video mode recording", state: camera) {
                AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { camera = ok } }
            }
            Text("You can change these later in the iOS Settings app.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .onAppear(perform: refresh)
    }

    private func permissionRow(_ icon: String, _ title: String, _ detail: String, state: Bool?, request: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 32).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let state {
                Image(systemName: state ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(state ? .green : .red)
            } else {
                Button("Allow", action: request).buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = true
        case .denied: mic = false
        default: mic = nil
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = true
        case .denied, .restricted: speech = false
        default: speech = nil
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = true
        case .denied, .restricted: camera = false
        default: camera = nil
        }
    }
}
