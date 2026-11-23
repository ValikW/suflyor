import SwiftUI
import Combine
import AVFoundation
import Photos

@main
struct SuflyorApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark).statusBarHidden() }
    }
}

// MARK: - Камера: фронталка + микрофон, запись в Фото

final class Camera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    @Published var recording = false
    @Published var message: String?

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return show("Нет доступа к камере — включи в Настройках") }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            DispatchQueue.global(qos: .userInitiated).async { self.configure() }
        }
    }

    private func configure() {
        guard session.inputs.isEmpty else { return session.startRunning() }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        session.commitConfiguration()
        session.startRunning()
    }

    func toggle() {
        if output.isRecording { return output.stopRecording() }
        guard output.connection(with: .video) != nil else { return show("Камера недоступна") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        output.startRecording(to: url, recordingDelegate: self)
        recording = true
    }

    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo url: URL, from _: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.recording = false }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                try? FileManager.default.removeItem(at: url)
                self.show(ok ? "Сохранено в Фото" : "Не удалось сохранить — разреши доступ к Фото")
            }
        }
    }

    private func show(_ text: String) {
        DispatchQueue.main.async {
            self.message = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.message = nil }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> View {
        let v = View()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: View, context: Context) {}
}

// MARK: - Экран

struct ContentView: View {
    @StateObject private var camera = Camera()
    @AppStorage("text") private var text = "Вставь сюда свой текст. Кнопка справа внизу — поменять текст.\n\nТап по окошку — старт и пауза. Двойной тап — в начало. Тяни окошко куда угодно, хоть под чёлку. Уголок справа внизу меняет размер."
    @AppStorage("speed") private var speed = 40.0      // точек в секунду
    @AppStorage("font") private var font = 30.0
    @AppStorage("boxX") private var boxX = -1.0        // центр окошка, -1 = ещё не ставили
    @AppStorage("boxY") private var boxY = -1.0
    @AppStorage("boxW") private var boxW = 340.0
    @AppStorage("boxH") private var boxH = 220.0

    @State private var playing = false
    @State private var scroll = 0.0
    @State private var textH = 0.0
    @State private var editing = false
    @State private var dragStart: CGPoint?
    @State private var sizeStart: CGSize?

    private let tick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            ZStack {
                CameraPreview(session: camera.session).ignoresSafeArea()
                controls.frame(maxHeight: .infinity, alignment: .bottom)
                prompter
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            let s = dragStart ?? CGPoint(x: boxX < 0 ? screen.width / 2 : boxX, y: boxY < 0 ? 120 : boxY)
                            dragStart = s
                            // по всему экрану, но центр не выпускаем за край, чтобы окно не потерялось
                            boxX = min(max(s.x + g.translation.width, 0), screen.width)
                            boxY = min(max(s.y + g.translation.height, 0), screen.height)
                        }
                        .onEnded { _ in dragStart = nil })
                    .position(x: boxX < 0 ? screen.width / 2 : boxX, y: boxY < 0 ? 120 : boxY)
                if let m = camera.message {
                    Text(m).padding(12).background(.black.opacity(0.8), in: Capsule())
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { camera.start(); UIApplication.shared.isIdleTimerDisabled = true }
        .onReceive(tick) { _ in
            guard playing else { return }
            scroll += speed / 60
            if scroll > textH { playing = false }
        }
        .sheet(isPresented: $editing) { editor }
    }

    private var prompter: some View {
        Text(text)
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: max(boxW - 24, 40), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { textH = $0 }
            .offset(y: boxH * 0.25 - scroll)
            .frame(width: boxW, height: boxH, alignment: .top)
            .clipped()
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomTrailing) { resizeHandle }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { scroll = 0; playing = false }
            .onTapGesture { if scroll >= textH { scroll = 0 }; playing.toggle() }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 14, weight: .bold))
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.25), in: Circle())
            .padding(4)
            .highPriorityGesture(DragGesture()
                .onChanged { g in
                    let s = sizeStart ?? CGSize(width: boxW, height: boxH)
                    sizeStart = s
                    boxW = max(120, s.width + g.translation.width * 2)   // *2: окно растёт от центра
                    boxH = max(80, s.height + g.translation.height * 2)
                }
                .onEnded { _ in sizeStart = nil })
    }

    private var controls: some View {
        VStack(spacing: 10) {
            slider("Скорость", $speed, 10...150)
            slider("Шрифт", $font, 16...60)
            HStack {
                button(playing ? "pause.fill" : "play.fill") { if scroll >= textH { scroll = 0 }; playing.toggle() }
                Spacer()
                Button(action: camera.toggle) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        RoundedRectangle(cornerRadius: camera.recording ? 6 : 31)
                            .fill(.red)
                            .frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: camera.recording)
                Spacer()
                button("text.alignleft") { playing = false; editing = true }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .padding(.top, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(width: 56, height: 56).background(.white.opacity(0.2), in: Circle())
        }
        .foregroundStyle(.white)
    }

    private var editor: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.title3)
                .padding()
                .navigationTitle("Текст")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Вставить") { if let s = UIPasteboard.general.string { text = s } }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Готово") { scroll = 0; editing = false }
                    }
                }
        }
    }
}
