import AVFoundation
import Photos
import SwiftUI

/// Foto: ein Auslösen → niedriger ISO, normal, hoher ISO (+ optional Blitz).
/// Video: Aufnahme mit Ton.
/// Alles wird in Fotos gesichert und an den Mac geschickt.
final class CameraModel: NSObject, ObservableObject,
    AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate
{
    static let port = 8765

    let session = AVCaptureSession()
    @Published var status = "Kamera wird gestartet…"
    @Published var busy = false
    @Published var ready = false
    @Published var recording = false

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "dreifach.camera")
    private var device: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?

    // Zustand der laufenden Aufnahme (nur auf dem Main-Thread verändert)
    private var stamp = ""
    private var macHost = ""
    private var useFlash = true
    private var bracketKinds: [String] = []
    private var total = 0
    private var sent = 0
    private var failed = 0

    // MARK: Einrichtung

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.setStatus("Kein Kamerazugriff. Bitte in den Einstellungen erlauben.")
                return
            }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard
            let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: cam),
            session.canAddInput(input),
            session.canAddOutput(photoOutput)
        else {
            session.commitConfiguration()
            setStatus("Kamera konnte nicht gestartet werden.")
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()
        device = cam
        fixRotation()
        session.startRunning()
        DispatchQueue.main.async {
            self.ready = true
            self.status = "Bereit"
        }
    }

    private func fixRotation() {
        for out in [photoOutput, movieOutput] as [AVCaptureOutput] {
            if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90 // Hochformat
            }
        }
    }

    /// Schaltet zwischen Foto- und Videomodus um.
    func setVideoMode(_ video: Bool) {
        if video {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async { self.applyMode(video: true) }
            }
        } else {
            queue.async { self.applyMode(video: false) }
        }
    }

    private func applyMode(video: Bool) {
        guard device != nil, !movieOutput.isRecording else { return }
        session.beginConfiguration()
        if video {
            session.sessionPreset = .high
            if audioInput == nil,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input)
            {
                session.addInput(input)
                audioInput = input
            }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
        } else {
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            if let input = audioInput {
                session.removeInput(input)
                audioInput = nil
            }
            session.sessionPreset = .photo
        }
        session.commitConfiguration()
        fixRotation()
    }

    private func beginCapture(host: String) {
        sent = 0
        failed = 0
        macHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        stamp = f.string(from: Date())
    }

    // MARK: Fotos

    /// - Parameters:
    ///   - ev: ISO-Abstand in Blendenstufen (z. B. 3 → ISO ÷ 8 und ISO × 8)
    ///   - flash: zusätzlich ein Foto mit Blitz aufnehmen
    ///   - host: Adresse des Macs, z. B. "MacBook.local" oder "192.168.1.20"
    func shoot(ev: Double, flash: Bool, host: String) {
        guard ready, !busy else { return }
        busy = true
        status = "Aufnahme läuft…"
        beginCapture(host: host)
        useFlash = flash
        total = flash ? 4 : 3

        queue.async {
            guard let device = self.device else { return }
            // Gleiche Belichtungszeit, nur der ISO-Wert ändert sich:
            // niedriger ISO = dunkler und rauscharm, hoher ISO = heller und körniger.
            let format = device.activeFormat
            let duration = device.exposureDuration
            let factor = Float(pow(2.0, ev))
            let normal = min(max(device.iso, format.minISO), format.maxISO)
            let low = max(format.minISO, normal / factor)
            let high = min(format.maxISO, normal * factor)
            var isos: [Float] = [low, normal, high]
            var kinds = ["1-iso-niedrig", "2-normal", "3-iso-hoch"]
            if self.photoOutput.maxBracketedCapturePhotoCount < 3 {
                isos = [low, high]
                kinds = ["1-iso-niedrig", "3-iso-hoch"]
                DispatchQueue.main.async { self.total -= 1 }
            }
            self.bracketKinds = kinds
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: 0,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
                bracketedSettings: isos.map {
                    AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                        exposureDuration: duration, iso: $0)
                }
            )
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func shootFlash() {
        queue.async {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            if self.photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = .on
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            setStatus("Fehler bei der Aufnahme: \(error?.localizedDescription ?? "unbekannt")")
            return
        }
        let kind: String
        if photo.bracketSettings != nil {
            // sequenceCount zählt die Bilder der Reihe ab 1
            let index = min(max(photo.sequenceCount - 1, 0), bracketKinds.count - 1)
            kind = bracketKinds[index]
        } else {
            kind = "4-blitz"
        }
        DispatchQueue.main.async {
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            self.upload(name: "\(self.stamp)_\(kind).jpg", type: "image/jpeg", data: data) { ok in
                if ok { self.sent += 1 } else { self.failed += 1 }
                if self.failed > 0 {
                    self.status = "Mac nicht erreichbar – \(self.sent)/\(self.total) gesendet (Bilder sind in Fotos)"
                } else {
                    self.status = "\(self.sent)/\(self.total) auf dem Mac gespeichert"
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async {
            if resolvedSettings.expectedPhotoCount > 1, self.useFlash, error == nil {
                self.shootFlash() // ISO-Reihe fertig → jetzt das Blitzfoto
            } else {
                self.busy = false
            }
        }
    }

    // MARK: Video

    func toggleRecording(host: String) {
        guard ready else { return }
        if !recording { beginCapture(host: host) }
        let name = "\(stamp)_video.mov"
        queue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else if self.session.outputs.contains(self.movieOutput) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: url)
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.recording = true
            self.status = "Video läuft…"
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let finished = error == nil
            || ((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
        DispatchQueue.main.async {
            self.recording = false
            guard finished else {
                self.status = "Fehler beim Video: \(error?.localizedDescription ?? "unbekannt")"
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.status = "Video wird gesichert…"
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: outputFileURL, options: nil)
            } completionHandler: { _, _ in
                DispatchQueue.main.async {
                    if !self.macHost.isEmpty { self.status = "Video wird an den Mac gesendet…" }
                    self.upload(name: outputFileURL.lastPathComponent, type: "video/quicktime", file: outputFileURL) { ok in
                        try? FileManager.default.removeItem(at: outputFileURL)
                        self.status = ok
                            ? "Video auf dem Mac gespeichert"
                            : "Mac nicht erreichbar (Video ist in Fotos)"
                    }
                }
            }
        }
    }

    // MARK: Senden an den Mac

    /// Muss auf dem Main-Thread aufgerufen werden; `done` kommt ebenfalls dort an.
    private func upload(name: String, type: String, data: Data? = nil, file: URL? = nil, done: @escaping (Bool) -> Void) {
        guard !macHost.isEmpty else {
            if let file { try? FileManager.default.removeItem(at: file) }
            status = "In Fotos gespeichert (kein Mac eingestellt)"
            return
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = macHost
        comps.port = Self.port
        comps.path = "/upload"
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = comps.url else {
            status = "Mac-Adresse ungültig"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        let handler: (Data?, URLResponse?, Error?) -> Void = { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }
        if let file {
            URLSession.shared.uploadTask(with: req, fromFile: file, completionHandler: handler).resume()
        } else {
            URLSession.shared.uploadTask(with: req, from: data ?? Data(), completionHandler: handler).resume()
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.status = text
            self.busy = false
        }
    }
}
