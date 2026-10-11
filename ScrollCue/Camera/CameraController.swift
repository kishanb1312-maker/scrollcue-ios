import AVFoundation
import Photos
import UIKit

/// Video recording with the prompter shown near the lens.
final class CameraController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var hdrAvailable = false
    @Published var lastTake: URL?
    @Published var error: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "scrollcue.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private var config: (lens: CameraLens, resolution: VideoResolution, fps: Int, hdr: Bool)?

    override init() {
        super.init()
        availableLenses = CameraLens.allCases.filter { Self.device(for: $0) != nil }
        // Share the app's audio session so voice tracking and recording can both use the mic.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.usesApplicationAudioSession = true
    }

    static func device(for lens: CameraLens) -> AVCaptureDevice? {
        switch lens {
        case .front: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .wide: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .ultraWide: return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .telephoto: return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
    }

    func requestAccessAndStart(lens: CameraLens, resolution: VideoResolution, fps: Int, hdr: Bool) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.error = "Camera access is off. Enable it in Settings › ScrollCue." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.configure(lens: lens, resolution: resolution, fps: fps, hdr: hdr)
            }
        }
    }

    func configure(lens: CameraLens, resolution: VideoResolution, fps: Int, hdr: Bool) {
        queue.async {
            if let c = self.config, c.lens == lens, c.resolution == resolution, c.fps == fps, c.hdr == hdr, self.session.isRunning { return }
            guard !self.movieOutput.isRecording else { return }
            AudioSession.activate()
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority

            if let v = self.videoInput { self.session.removeInput(v) }
            guard let device = Self.device(for: lens) ?? Self.device(for: .wide),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.error = "Couldn't open that camera." }
                return
            }
            self.session.addInput(input)
            self.videoInput = input

            if self.audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let a = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(a) {
                self.session.addInput(a)
                self.audioInput = a
            }
            if !self.session.outputs.contains(self.movieOutput), self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            let hdrOK = self.applyFormat(device: device, resolution: resolution, fps: fps, hdr: hdr)
            self.session.commitConfiguration()
            self.config = (lens, resolution, fps, hdr)

            if let conn = self.movieOutput.connection(with: .video) {
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = lens == .front
                }
                if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .auto }
            }
            if let codec = self.movieOutput.availableVideoCodecTypes.first(where: { $0 == .hevc }),
               let conn = self.movieOutput.connection(with: .video) {
                self.movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }

            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.hdrAvailable = hdrOK
                self.isRunning = self.session.isRunning
                self.setupRotation(device: device)
            }
        }
    }

    /// Picks a format matching the resolution / frame rate (and 10-bit HLG if requested).
    @discardableResult
    private func applyFormat(device: AVCaptureDevice, resolution: VideoResolution, fps: Int, hdr: Bool) -> Bool {
        let tenBit: FourCharCode = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == resolution.width && d.height == resolution.height &&
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) && $0.minFrameRate <= Double(fps) }
        }
        let hdrFormats = candidates.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == tenBit && $0.supportedColorSpaces.contains(.HLG_BT2020)
        }
        let anyHDR = !device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == tenBit && $0.supportedColorSpaces.contains(.HLG_BT2020)
        }.isEmpty

        let chosen: AVCaptureDevice.Format?
        if hdr, let f = hdrFormats.first { chosen = f }
        else { chosen = candidates.first { CMFormatDescriptionGetMediaSubType($0.formatDescription) != tenBit } ?? candidates.first }

        do {
            try device.lockForConfiguration()
            if let chosen {
                device.activeFormat = chosen
                if hdr && chosen.supportedColorSpaces.contains(.HLG_BT2020) {
                    session.automaticallyConfiguresCaptureDeviceForWideColor = false
                    device.activeColorSpace = .HLG_BT2020
                } else {
                    session.automaticallyConfiguresCaptureDeviceForWideColor = true
                }
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } else {
                DispatchQueue.main.async { self.error = "\(resolution.label) at \(fps) fps isn't available on this camera. Using the default format." }
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription }
        }
        return anyHDR
    }

    private func setupRotation(device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation()
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPreviewRotation() }
        }
    }

    private func applyPreviewRotation() {
        guard let coordinator = rotationCoordinator, let conn = previewLayer?.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }

    func stopSession() {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            self.config = nil
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        queue.async {
            guard !self.movieOutput.isRecording else { return }
            if let angle, let conn = self.movieOutput.connection(with: .video), conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = Storage.takesDirectory.appendingPathComponent("Take \(formatter.string(from: Date())).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStarted = Date()
            }
        }
    }

    func stopRecording() {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    // MARK: Takes

    static func saveToPhotos(_ url: URL, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false, "Photos access is off. Enable it in Settings › ScrollCue.") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, err in
                if ok { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { completion(ok, err?.localizedDescription) }
            }
        }
    }

    static func leftoverTakes() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Storage.takesDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mov" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStarted = nil
            let ok = (error == nil) || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
            if ok { self.lastTake = url } else { self.error = error?.localizedDescription }
        }
    }
}
