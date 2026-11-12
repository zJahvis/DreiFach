import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @AppStorage("macHost") private var macHost = ""
    @AppStorage("ev") private var ev = 3.0
    @AppStorage("flash") private var flash = true
    @State private var videoMode = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            VStack {
                HStack {
                    if !videoMode {
                        Button { flash.toggle() } label: {
                            Label(flash ? "Blitz an" : "Blitz aus",
                                  systemImage: flash ? "bolt.fill" : "bolt.slash.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .tint(flash ? .yellow : .white)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .tint(.white)
                }
                .padding()

                Spacer()

                Text(camera.status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal)

                Picker("Modus", selection: $videoMode) {
                    Text("Foto").tag(false)
                    Text("Video").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(camera.recording || camera.busy)
                .padding(.top, 8)

                Button {
                    if videoMode {
                        camera.toggleRecording(host: macHost)
                    } else {
                        camera.shoot(ev: ev, flash: flash, host: macHost)
                    }
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 84, height: 84)
                        if videoMode {
                            RoundedRectangle(cornerRadius: camera.recording ? 8 : 36)
                                .fill(.red)
                                .frame(width: camera.recording ? 36 : 72, height: camera.recording ? 36 : 72)
                        } else {
                            Circle().fill(.white).frame(width: 72, height: 72)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: camera.recording)
                }
                .disabled(!camera.ready || camera.busy)
                .opacity(camera.ready && !camera.busy ? 1 : 0.4)
                .padding(.vertical, 20)
            }
        }
        .onAppear {
            camera.start()
            if macHost.isEmpty { showSettings = true }
        }
        .onChange(of: videoMode) { _, video in
            camera.setVideoMode(video)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(macHost: $macHost, ev: $ev)
        }
    }
}

struct SettingsView: View {
    @Binding var macHost: String
    @Binding var ev: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. MacBook.local", text: $macHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Adresse des Macs")
                } footer: {
                    Text("Die Adresse zeigt dir das Skript mac_empfaenger.py beim Start an. iPhone und Mac müssen im selben WLAN sein.")
                }

                Section {
                    Slider(value: $ev, in: 1...6, step: 0.5)
                    Text("Niedriger ISO: −\(ev, specifier: "%.1f") Stufen · Hoher ISO: +\(ev, specifier: "%.1f") Stufen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("ISO-Abstand zum Normalfoto")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        if let layer = view.layer as? AVCaptureVideoPreviewLayer {
            layer.session = session
            layer.videoGravity = .resizeAspectFill
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
