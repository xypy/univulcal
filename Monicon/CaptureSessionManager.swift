import AVFoundation
import Combine
import CoreMedia
import CoreGraphics
import Photos
import UIKit

enum VideoDisplayMode: String, CaseIterable, Identifiable {
    case fit
    case stretch
    case fill

    var id: String { rawValue }
    var localizedTitle: String { NSLocalizedString("display.\(rawValue)", comment: "") }
}

final class CaptureSessionManager: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var status = "Connect a UVC capture card"
    @Published var selectedResolution = "Auto"
    @Published var selectedFrameRate = "Auto"
    @Published var devices: [AVCaptureDevice] = []
    @Published var directImage: CGImage?
    @Published var usesDirectUVC = true
    @Published var displayMode: VideoDisplayMode = .fit {
        didSet { if oldValue != displayMode { log("video.display", "mode=\(displayMode.rawValue)") } }
    }
    @Published var resolutionScale = 100 {
        didSet { if oldValue != resolutionScale { log("video.scale", "scale=\(resolutionScale)%") } }
    }
    @Published var audioEnabled = true
    @Published var isRecording = false
    @Published var lastAction = ""
    @Published var logMode = false

    private let directBackend = MNDirectUVCBackend()
    private let captureCardAudio = CaptureCardAudioRouter()
    private let recorder = CaptureRecorder()
    private var currentFrameWidth = 0
    private var currentFrameHeight = 0
    private var logTimer: Timer?
    private var lastLoggedFrameSize = ""

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "monicon.capture", qos: .userInteractive)

    let resolutionScales = [25, 50, 75, 100]
    let frameRates = ["Auto", "60 fps", "30 fps", "24 fps"]

    override init() {
        super.init()
        directBackend.delegate = self
        refreshDevices()
        session.sessionPreset = .high
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.prepare()
        log("manager", "ready")
    }

    func setLogMode(_ enabled: Bool) {
        logMode = enabled
        logTimer?.invalidate()
        logTimer = nil
        if enabled {
            logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.log("heartbeat", "ok")
            }
            log("log.mode", "enabled; file=Documents/monicon.log")
        }
    }

    private func log(_ section: String, _ message: String) {
        let isError = section.hasPrefix("ERROR") || message.hasPrefix("ERROR")
        guard logMode || isError else { return }
        let level = isError ? "error" : "log"
        let line = "[Monicon][\(level)][\(section)] \(message)"
        print(line)
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = documents.appendingPathComponent("monicon.log")
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[Monicon][error][log.file] \(error.localizedDescription)")
        }
    }

    func refreshDevices() {
        devices = AVCaptureDevice.devices(for: .video)
        status = devices.isEmpty ? "Connect a UVC capture card" : "Ready: \(devices.count) capture card(s)"
    }

    func start(device: AVCaptureDevice? = nil) {
        log("capture.start", "requested; directUVC=\(usesDirectUVC)")
        if usesDirectUVC {
            let requestedFPS: UInt = selectedFrameRate == "30 fps" ? 30 : selectedFrameRate == "24 fps" ? 24 : 60
            log("uvc.start", "request native resolution; fps=\(requestedFPS)")
            directBackend.start(withWidth: 0, height: 0, fps: requestedFPS)
            DispatchQueue.main.async {
                self.isRunning = true
                if self.status == "Connect a UVC capture card" { self.status = "Opening direct UVC…" }
            }
            return
        }

        queue.async {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            let videoDevice = device ?? self.devices.first
            guard let videoDevice,
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
                  self.session.canAddInput(videoInput) else {
                DispatchQueue.main.async { self.status = "No compatible UVC video input" }
                return
            }
            self.session.addInput(videoInput)
            if let audioDevice = AVCaptureDevice.devices(for: .audio).first,
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
            }
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if self.session.canAddOutput(self.audioOutput) { self.session.addOutput(self.audioOutput) }
            self.applyFormat(to: videoDevice)
            self.session.startRunning()
            if self.audioEnabled {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .gameChat, options: [.allowBluetooth, .defaultToSpeaker])
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.audioEngine.start()
                self.audioPlayer.play()
            }
            DispatchQueue.main.async {
                self.isRunning = true
                self.status = self.audioEnabled ? "Live • capture-card audio only" : "Live • audio off"
            }
        }
    }

    func stop() {
        log("capture.stop", "requested")
        if isRecording { finishRecording() }
        if usesDirectUVC {
            directBackend.stop()
            captureCardAudio.stop()
            DispatchQueue.main.async {
                self.isRunning = false
                self.directImage = nil
                self.status = "Stopped"
            }
            return
        }
        queue.async {
            self.session.stopRunning()
            self.audioPlayer.stop()
            self.audioEngine.stop()
            DispatchQueue.main.async {
                self.isRunning = false
                self.status = "Stopped"
            }
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        log("audio.toggle", "enabled=\(enabled)")
        audioEnabled = enabled
        guard isRunning else { return }
        if enabled {
            do {
                if usesDirectUVC { try captureCardAudio.start() }
                else {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try audioEngine.start()
                    audioPlayer.play()
                }
                status = "Live • capture-card audio only"
            } catch {
                log("ERROR.audio.toggle", error.localizedDescription)
                audioEnabled = false
                status = "USB video live • capture-card audio unavailable"
            }
        } else {
            if usesDirectUVC {
                captureCardAudio.stop()
            } else {
                audioPlayer.stop()
                audioEngine.stop()
            }
            status = "Live • audio off"
        }
    }

    func toggleRecording() {
        log("recording.toggle", "isRecording=\(isRecording)")
        if isRecording {
            finishRecording()
            return
        }
        guard currentFrameWidth > 0, currentFrameHeight > 0 else {
            lastAction = "等待第一帧后才能录制"
            return
        }
        do {
            try recorder.start(width: currentFrameWidth, height: currentFrameHeight,
                               fps: selectedFrameRate == "30 fps" ? 30 : 60)
            isRecording = true
            lastAction = "录制中"
        } catch {
            lastAction = "录制启动失败"
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder.finish { [weak self] url in
            self?.lastAction = url == nil ? "录制失败" : "录制已保存到照片"
        }
    }

    func takeScreenshot() {
        log("screenshot", "requested")
        guard let directImage else {
            lastAction = "暂无画面可截图"
            return
        }
        let image = UIImage(cgImage: directImage)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] permission in
            guard permission == .authorized || permission == .limited else {
                DispatchQueue.main.async { self?.lastAction = "照片权限未开启" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { _, error in
                DispatchQueue.main.async {
                    self?.lastAction = error == nil ? "截图已保存到照片" : "截图保存失败"
                }
            }
        }
    }

    func applyFormat(to device: AVCaptureDevice) {
        guard selectedResolution != "Auto" || selectedFrameRate != "Auto" else { return }
        let width = selectedResolution == "1920 × 1080" ? 1920 : selectedResolution == "1280 × 720" ? 1280 : 720
        let height = selectedResolution == "1920 × 1080" ? 1080 : selectedResolution == "1280 × 720" ? 720 : 480
        let fps = selectedFrameRate == "60 fps" ? 60.0 : selectedFrameRate == "30 fps" ? 30.0 : 24.0
        guard let format = device.formats.first(where: { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == width && d.height == height && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }) else { return }
        try? device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
    }
}

extension CaptureSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === audioOutput,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr else { return }
        let source = UnsafeMutableAudioBufferListPointer(list)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { continue }
            memcpy(destinationData, sourceData, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
        }
        audioPlayer.scheduleBuffer(pcm)
    }
}

extension CaptureSessionManager: MNDirectUVCBackendDelegate {
    func uvcBackendDidLog(_ message: String) {
        log("ERROR.uvc.detail", message)
    }

    func uvcBackendDidStart(withWidth width: UInt, height: UInt, fps: UInt) {
        log("uvc.ready", "width=\(width) height=\(height) fps=\(fps)")
        var audioLive = false
        if audioEnabled {
            do {
                try captureCardAudio.start()
                audioLive = true
                log("audio.ready", "USB audio route active")
            } catch {
                log("ERROR.audio", error.localizedDescription)
            }
        }
        status = audioLive ? "Direct UVC live • capture-card audio"
            : (audioEnabled ? "USB video opened; capture-card audio unavailable" : "Direct UVC live • audio off")
        isRunning = true
    }

    func uvcBackendDidReceiveRGB(_ rgb: Data, width: UInt, height: UInt) {
        let sourceWidth = Int(width)
        let sourceHeight = Int(height)
        let expectedBytes = sourceWidth * sourceHeight * 3
        guard sourceWidth > 0, sourceHeight > 0, rgb.count >= expectedBytes else {
            log("ERROR.video.frame", "invalid frame width=\(sourceWidth) height=\(sourceHeight) bytes=\(rgb.count) expected=\(expectedBytes)")
            return
        }
        let scale = max(25, min(100, resolutionScale))
        let frameSize = "\(sourceWidth)x\(sourceHeight) -> \(scale)%"
        if frameSize != lastLoggedFrameSize {
            lastLoggedFrameSize = frameSize
            log("video.frame", frameSize)
        }
        let targetWidth = max(1, sourceWidth * scale / 100)
        let targetHeight = max(1, sourceHeight * scale / 100)
        let source = [UInt8](rgb)
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
        for y in 0..<targetHeight {
            let sourceY = min(sourceHeight - 1, y * sourceHeight / targetHeight)
            for x in 0..<targetWidth {
                let sourceX = min(sourceWidth - 1, x * sourceWidth / targetWidth)
                let sourceIndex = (sourceY * sourceWidth + sourceX) * 3
                let targetIndex = (y * targetWidth + x) * 3
                output[targetIndex] = source[sourceIndex]
                output[targetIndex + 1] = source[sourceIndex + 1]
                output[targetIndex + 2] = source[sourceIndex + 2]
            }
        }
        let scaledRGB = Data(output)
        currentFrameWidth = targetWidth
        currentFrameHeight = targetHeight
        if isRecording { recorder.append(rgb: scaledRGB, width: targetWidth, height: targetHeight) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: scaledRGB as CFData)
        directImage = CGImage(width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                              bitsPerPixel: 24, bytesPerRow: targetWidth * 3,
                              space: colorSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider!, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)
    }

    func uvcBackendDidFail(_ message: String) {
        log("ERROR.uvc", message)
        isRunning = false
        status = "Direct UVC failed: \(message)"
    }
}
