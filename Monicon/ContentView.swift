import SwiftUI
import AVFoundation

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureSessionManager
    @State private var showSettings = false
    @State private var isFullscreen = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if !isFullscreen {
                    HStack {
                        Label(L("app.name"), systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline.weight(.bold))
                        Spacer()
                        Circle().fill(capture.isRunning ? .green : .gray).frame(width: 8, height: 8)
                        Text(capture.isRunning ? L("status.live") : L("status.idle"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }

                GeometryReader { _ in
                    ZStack {
                        RoundedRectangle(cornerRadius: isFullscreen ? 0 : 18)
                            .fill(Color(red: 0.06, green: 0.07, blue: 0.09))

                        if let directImage = capture.directImage {
                            DirectImagePreview(image: directImage, mode: capture.displayMode)
                                .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 14))
                                .padding(isFullscreen ? 0 : 10)
                        } else if capture.isRunning {
                            VideoPreview(session: capture.session, mode: capture.displayMode)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 14))
                                .padding(isFullscreen ? 0 : 10)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.inset.filled.and.person.filled")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.secondary)
                                Text(L("screen.placeholder.title"))
                                    .font(.title3.weight(.semibold))
                                Text(L("screen.placeholder.subtitle"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            isFullscreen.toggle()
                        }
                    )
                }

                if !isFullscreen {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capture.status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if !capture.lastAction.isEmpty {
                                Text(capture.lastAction)
                                    .font(.caption)
                                    .foregroundStyle(capture.isRecording ? .red : .secondary)
                            }
                        }
                        Spacer()
                        CaptureActionButton(isRecording: capture.isRecording,
                                            onSingleTap: { capture.takeScreenshot() },
                                            onDoubleTap: { capture.toggleRecording() })
                            .frame(width: 58, height: 44)
                        Button(capture.isRunning ? L("button.stop") : L("button.start")) {
                            capture.isRunning ? capture.stop() : capture.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(capture) }
        .onAppear { capture.refreshDevices() }
    }
}

struct DirectImagePreview: View {
    let image: CGImage
    let mode: VideoDisplayMode

    var body: some View {
        let source = Image(decorative: image, scale: 1, orientation: .up).resizable()
        Group {
            switch mode {
            case .fit: source.aspectRatio(contentMode: .fit)
            case .stretch: source
            case .fill: source.aspectRatio(contentMode: .fill).clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CaptureActionButton: View {
    let isRecording: Bool
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    @State private var pendingSingleTap: DispatchWorkItem?

    var body: some View {
        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
            .font(.system(size: 28))
            .foregroundStyle(isRecording ? .red : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                pendingSingleTap?.cancel()
                onDoubleTap()
            }
            .onTapGesture(count: 1) {
                let work = DispatchWorkItem { onSingleTap() }
                pendingSingleTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
            }
            .accessibilityLabel(L(isRecording ? "record.stop.accessibility" : "record.accessibility"))
            .accessibilityHint(L("record.hint"))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var capture: CaptureSessionManager

    var body: some View {
        NavigationStack {
            Form {
                Section(L("settings.capture")) {
                    Picker(L("settings.captureResolution"), selection: $capture.selectedResolution) {
                        ForEach(capture.captureResolutions, id: \.self) { value in
                            Text(value == "Auto" ? L("settings.captureResolution.auto") : value).tag(value)
                        }
                    }
                    Text(L("settings.captureResolution.help")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("settings.scale"), selection: $capture.resolutionScale) {
                        ForEach(capture.resolutionScales, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                    Text(L("settings.scale.help")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("settings.frameRate"), selection: $capture.selectedFrameRate) {
                        ForEach(capture.frameRates, id: \.self) { value in Text(value) }
                    }
                    Text(L("settings.frameRate.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("settings.audio")) {
                    Toggle(isOn: Binding(
                        get: { capture.audioEnabled },
                        set: { capture.setAudioEnabled($0) }
                    )) {
                        Label(L("settings.audio"), systemImage: "speaker.wave.2.fill")
                    }
                    Text(L("settings.audio.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("settings.log")) {
                    Toggle(isOn: Binding(
                        get: { capture.logMode },
                        set: { capture.setLogMode($0) }
                    )) {
                        Label(L("settings.log"), systemImage: "waveform.path.ecg")
                    }
                    Text(L("settings.log.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("settings.video")) {
                    Picker(L("settings.video.mode"), selection: $capture.displayMode) {
                        ForEach(VideoDisplayMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    Text(L("settings.video.help")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("settings.links")) {
                    Link(L("link.issue"), destination: URL(string: "https://github.com/xypy/univulcal/issues/new")!)
                    Link(L("link.repository"), destination: URL(string: "https://github.com/xypy/univulcal")!)
                }
            }
            .navigationTitle(L("settings.title"))
        }
    }
}

struct VideoPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mode: VideoDisplayMode

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.set(mode: mode)
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.set(mode: mode)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        videoPreviewLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    func set(mode: VideoDisplayMode) {
        switch mode {
        case .fit: videoPreviewLayer.videoGravity = .resizeAspect
        case .stretch: videoPreviewLayer.videoGravity = .resize
        case .fill: videoPreviewLayer.videoGravity = .resizeAspectFill
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
