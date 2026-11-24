import AVFoundation
import Foundation

enum CaptureState {
    case preparing
    case running(hasAudio: Bool)
    case interrupted(String)
    case failed(String)
    case stopped
}

/// Configures hardware off the main thread. State, paired video (back, front), and
/// audio all reach the client on its serial sample queue.
final class CaptureSession {
    private let sessionQueue = DispatchQueue(label: "dualcam.capture.hardware", qos: .userInitiated)
    private let sampleQueue: DispatchQueue
    private let onVideo: (CMSampleBuffer, CMSampleBuffer) -> Void
    private let onAudio: (CMSampleBuffer) -> Void
    private let onState: (CaptureState) -> Void

    // These properties are accessed only by sessionQueue.
    private var graph: Graph?
    private var observers: [NSObjectProtocol] = []
    private var wantsRunning = false
    private var generation = 0
    private var recoveredFromReset = false

    init(sampleQueue: DispatchQueue,
         onVideo: @escaping (CMSampleBuffer, CMSampleBuffer) -> Void,
         onAudio: @escaping (CMSampleBuffer) -> Void,
         onState: @escaping (CaptureState) -> Void) {
        self.sampleQueue = sampleQueue
        self.onVideo = onVideo
        self.onAudio = onAudio
        self.onState = onState
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let session = graph?.session {
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    func start() {
        sessionQueue.async { [self] in
            guard !wantsRunning else { return }
            wantsRunning = true
            recoveredFromReset = false
            generation += 1
            let request = generation
            publish(.preparing)
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                fail("這部裝置不支援前後鏡頭同時拍攝。請使用支援雙鏡拍攝的實體 iPhone。")
                return
            }
            authorize(.video, request: request) { [self] allowed in
                guard allowed else {
                    fail("請到「設定」開啟此 App 的相機權限，再重新啟動相機。")
                    return
                }
                authorize(.audio, request: request) { [self] hasMicrophone in
                    configureAndStart(withAudio: hasMicrophone)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            generation += 1
            tearDown()
            publish(.stopped)
        }
    }

    private func authorize(_ type: AVMediaType, request: Int, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.async {
                    guard self.wantsRunning, self.generation == request else { return }
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private func configureAndStart(withAudio: Bool) {
        do {
            let newGraph = try buildGraph(withAudio: withAudio)
            graph = newGraph
            observe(newGraph.session)
            resume(newGraph)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func resume(_ graph: Graph) {
        if !graph.session.isRunning { graph.session.startRunning() }
        if graph.session.isInterrupted {
            publish(.interrupted("相機暫時被系統中斷，恢復後會自動重新開啟。"))
        } else if graph.session.isRunning {
            publish(.running(hasAudio: graph.hasAudio))
        } else {
            fail("相機未能啟動。請關閉其他正在使用相機的 App，再試一次。")
        }
    }

    private func publish(_ state: CaptureState) {
        sampleQueue.async { [onState] in onState(state) }
    }

    private func fail(_ message: String) {
        wantsRunning = false
        tearDown()
        publish(.failed(message))
    }

    private func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let graph, graph.session.isRunning { graph.session.stopRunning() }
        graph = nil
    }

    private func observe(_ session: AVCaptureSession) {
        let notifications: [Notification.Name] = [
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.interruptionEndedNotification,
            AVCaptureSession.runtimeErrorNotification
        ]
        for name in notifications {
            let token = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) {
                [weak self, weak session] note in
                guard let self, let session else { return }
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.sessionQueue.async {
                    guard self.wantsRunning, let active = self.graph, active.session === session else { return }
                    switch name {
                    case AVCaptureSession.wasInterruptedNotification:
                        self.publish(.interrupted("拍攝已中斷。通話、裝置溫度或其他 App 可能暫時佔用了鏡頭。"))
                    case AVCaptureSession.interruptionEndedNotification:
                        self.resume(active)
                    default:
                        if error?.domain == AVFoundationErrorDomain,
                           error?.code == AVError.Code.mediaServicesWereReset.rawValue,
                           !self.recoveredFromReset {
                            self.recoveredFromReset = true
                            self.publish(.interrupted("系統正在重新啟動相機。"))
                            self.tearDown()
                            self.configureAndStart(withAudio: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
                        } else {
                            self.fail(error?.localizedDescription ?? "相機發生錯誤，請重新開啟。")
                        }
                    }
                }
            }
            observers.append(token)
        }
    }

    private struct Graph {
        let session: AVCaptureMultiCamSession
        // Capture objects hold weak delegates. Retain the receiver and synchronizer together.
        let synchronizer: AVCaptureDataOutputSynchronizer
        let receiver: SampleReceiver
        let hasAudio: Bool
    }

    private struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func cameraPair() throws -> (back: AVCaptureDevice, front: AVCaptureDevice) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .unspecified
        )
        guard let back = discovery.devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) else {
            throw SetupError("找不到後置廣角鏡頭。")
        }
        let frontOptions = discovery.devices.filter { $0.position == .front }
        // Prefer the RGB wide camera where it participates in a supported device set.
        for type in [AVCaptureDevice.DeviceType.builtInWideAngleCamera, .builtInTrueDepthCamera] {
            if let front = frontOptions.first(where: { front in
                front.deviceType == type && discovery.supportedMultiCamDeviceSets.contains {
                    $0.contains(back) && $0.contains(front)
                }
            }) { return (back, front) }
        }
        throw SetupError("這部裝置沒有可同時使用的前後鏡頭組合。")
    }

    private func buildGraph(withAudio: Bool) throws -> Graph {
        let pair = try cameraPair()
        let backInput = try AVCaptureDeviceInput(device: pair.back)
        let frontInput = try AVCaptureDeviceInput(device: pair.front)
        let backOutput = AVCaptureVideoDataOutput()
        let frontOutput = AVCaptureVideoDataOutput()
        let session = AVCaptureMultiCamSession()
        var audioOutput: AVCaptureAudioDataOutput?
        var activeFPS: Int32 = 0

        // Some devices expose only 1080p for a given lens. Choose a valid format at
        // each attempt, then check the combined hardware cost AFTER the commit.
        let profiles: [(width: Int32, fps: Int32)] = [(1280, 30), (1280, 24), (640, 24)]
        var connected = false
        for profile in profiles {
            guard let back = selectedFormat(pair.back, width: profile.width, fps: profile.fps),
                  let front = selectedFormat(pair.front, width: profile.width, fps: profile.fps) else { continue }
            session.beginConfiguration()
            do {
                if !connected {
                    try connectVideo(backInput, to: backOutput, in: session)
                    try connectVideo(frontInput, to: frontOutput, in: session)
                    if withAudio { audioOutput = connectMicrophone(in: session) }
                    connected = true
                }
                // Adding an input resets its active frame durations and duration override.
                try apply(back, to: backInput, fps: profile.fps)
                try apply(front, to: frontInput, fps: profile.fps)
                configurePixels(backOutput)
                configurePixels(frontOutput)
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()
                throw error
            }
            if session.hardwareCost <= 1 && (session.systemPressureCost <= 1 || profile.width == 640) {
                activeFPS = profile.fps
                break
            }
        }
        guard activeFPS > 0 else { throw SetupError("無法在這部裝置上配置雙鏡拍攝。") }
        let receiver = SampleReceiver(back: backOutput, front: frontOutput, fps: activeFPS,
                                      onVideo: onVideo, onAudio: onAudio)
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [backOutput, frontOutput])
        synchronizer.setDelegate(receiver, queue: sampleQueue)
        audioOutput?.setSampleBufferDelegate(receiver, queue: sampleQueue)
        return Graph(session: session, synchronizer: synchronizer, receiver: receiver, hasAudio: audioOutput != nil)
    }

    private func selectedFormat(_ device: AVCaptureDevice, width: Int32, fps: Int32) -> AVCaptureDevice.Format? {
        let options = device.formats.filter { format in
            format.isMultiCamSupported && format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(fps) && range.maxFrameRate >= Double(fps)
            }
        }
        // Consent to a larger format only if the camera has no smaller multicam format.
        func score(_ format: AVCaptureDevice.Format) -> Int {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let oversizePenalty = dims.width > width ? 1_000_000 : 0
            let sizeDifference = abs(Int(dims.width) - Int(width)) * 100
            let aspectDifference = abs(Int(dims.height) * 16 - Int(dims.width) * 9)
            let native8Bit = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return oversizePenalty + sizeDifference + aspectDifference + (format.isVideoBinned ? 0 : 2) + (native8Bit ? 0 : 1)
        }
        return options.min { score($0) < score($1) }
    }

    private func apply(_ format: AVCaptureDevice.Format, to input: AVCaptureDeviceInput, fps: Int32) throws {
        let device = input.device
        let duration = CMTime(value: 1, timescale: fps)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        input.videoMinFrameDurationOverride = duration
    }

    private func connectVideo(_ input: AVCaptureDeviceInput, to output: AVCaptureVideoDataOutput,
                              in session: AVCaptureMultiCamSession) throws {
        guard session.canAddInput(input) else { throw SetupError("無法加入其中一個鏡頭。") }
        session.addInputWithNoConnections(input)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw SetupError("無法建立雙鏡影像輸出。") }
        session.addOutputWithNoConnections(output)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            throw SetupError("無法讀取鏡頭影像。")
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw SetupError("無法連接前後鏡頭。") }
        session.addConnection(connection)
        // The app is portrait-only. This semantic orientation handles front and back
        // sensors' different physical mountings, including when the camera is unmirrored.
        guard connection.isVideoOrientationSupported else { throw SetupError("鏡頭無法提供直向影像。") }
        connection.videoOrientation = .portrait
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
    }

    private func configurePixels(_ output: AVCaptureVideoDataOutput) {
        let preferredTypes: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
        if let match = preferredTypes.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: match]
        }
    }

    private func connectMicrophone(in session: AVCaptureMultiCamSession) -> AVCaptureAudioDataOutput? {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInputWithNoConnections(input)
        let output = AVCaptureAudioDataOutput()
        let audioPorts = input.ports.filter { $0.mediaType == .audio }
        guard let port = audioPorts.first(where: { $0.sourceDevicePosition == .unspecified }) ?? audioPorts.first,
              session.canAddOutput(output) else {
            session.removeInput(input)
            return nil
        }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            session.removeOutput(output)
            session.removeInput(input)
            return nil
        }
        session.addConnection(connection)
        return output
    }
}

private final class SampleReceiver: NSObject, AVCaptureDataOutputSynchronizerDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let back: AVCaptureVideoDataOutput
    private let front: AVCaptureVideoDataOutput
    private let maxSkew: Double
    private let onVideo: (CMSampleBuffer, CMSampleBuffer) -> Void
    private let onAudio: (CMSampleBuffer) -> Void
    // The two independent sensors may have slightly different exposure timestamps.
    // A synchronizer can deliver them in adjacent callbacks. Retain at most one
    // sample per lens and only compose pairs captured within one frame period.
    private var pendingBack: CMSampleBuffer?
    private var pendingFront: CMSampleBuffer?

    init(back: AVCaptureVideoDataOutput, front: AVCaptureVideoDataOutput, fps: Int32,
         onVideo: @escaping (CMSampleBuffer, CMSampleBuffer) -> Void, onAudio: @escaping (CMSampleBuffer) -> Void) {
        self.back = back
        self.front = front
        maxSkew = 1 / Double(fps)
        self.onVideo = onVideo
        self.onAudio = onAudio
        super.init()
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        if let rearFrame = validSample(in: collection, for: back) { pendingBack = rearFrame }
        if let frontFrame = validSample(in: collection, for: front) { pendingFront = frontFrame }
        guard let rearFrame = pendingBack, let frontFrame = pendingFront else { return }
        let delta = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(rearFrame),
                                   CMSampleBufferGetPresentationTimeStamp(frontFrame)).seconds
        guard delta.isFinite else {
            pendingBack = nil
            pendingFront = nil
            return
        }
        if abs(delta) <= maxSkew {
            pendingBack = nil
            pendingFront = nil
            onVideo(rearFrame, frontFrame)
        } else if delta < 0 {
            pendingBack = nil
        } else {
            pendingFront = nil
        }
    }

    private func validSample(in collection: AVCaptureSynchronizedDataCollection,
                             for output: AVCaptureVideoDataOutput) -> CMSampleBuffer? {
        guard let data = collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData,
              !data.sampleBufferWasDropped, CMSampleBufferDataIsReady(data.sampleBuffer) else { return nil }
        return data.sampleBuffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if CMSampleBufferDataIsReady(sampleBuffer) { onAudio(sampleBuffer) }
    }
}
