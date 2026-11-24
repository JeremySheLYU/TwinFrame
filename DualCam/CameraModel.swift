import AVFoundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class CameraModel: ObservableObject {
    @Published var mode: CameraMode = .photo
    @Published private(set) var isRecording = false
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var frontIsPrimary = false
    @Published private(set) var micEnabled = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var notice: String?
    @Published private(set) var problem: String?
    @Published private(set) var needsSettings = false

    let preview = PreviewSurface()
    private let media = MediaPipeline()
    private lazy var capture = CaptureSession(
        sampleQueue: DispatchQueue(label: "TwinFrame.samples", qos: .userInitiated),
        onVideo: media.consumeVideo(back:front:), onAudio: media.consumeAudio,
        onState: { [weak self] state in
            DispatchQueue.main.async { self?.apply(state) }
        }
    )

    private var foreground = false
    private var sessionRunning = false
    private var frameSeen = false
    private var firstFrameTimeout: Task<Void, Never>?
    private var dismissNotice: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var recordingID: UUID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let store = CaptureStore()

    init() {
        media.onPreview = preview.submit
        preview.onFirstFrame = { [weak self] in
            guard let self, self.foreground else { return }
            self.frameSeen = true
            if self.sessionRunning { self.markReady() }
        }
    }

    func activate() {
        guard !foreground else { return }
        foreground = true
        resetViewfinder()
        capture.start()
    }

    func deactivate() {
        guard foreground else { return }
        foreground = false
        if isRecording { finishRecording() }
        resetViewfinder()
        capture.stop()
    }

    func retry() {
        guard foreground, !isRecording else { return }
        resetViewfinder()
        capture.stop()
        capture.start()
    }

    func swap() {
        guard ready, !busy, !isRecording else { return }
        frontIsPrimary.toggle()
        media.setFrontPrimary(frontIsPrimary)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func shutter() {
        if isRecording {
            finishRecording()
            return
        }
        guard foreground, ready, !busy, problem == nil else { return }
        notice = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch mode {
        case .photo: photograph()
        case .video: beginRecording()
        }
    }

    private func resetViewfinder() {
        firstFrameTimeout?.cancel()
        sessionRunning = false
        frameSeen = false
        ready = false
        micEnabled = false
        problem = nil
        needsSettings = false
        preview.reset()
    }

    private func apply(_ state: CaptureState) {
        guard foreground else { return }
        switch state {
        case .preparing:
            problem = nil
            needsSettings = false
        case .running(let hasAudio):
            sessionRunning = true
            micEnabled = hasAudio
            problem = nil
            if frameSeen {
                markReady()
            } else {
                firstFrameTimeout?.cancel()
                firstFrameTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    guard let self, self.sessionRunning, !self.ready else { return }
                    self.problem = "還未收到前後鏡頭的畫面，請重試。"
                }
            }
        case .failed(let message), .interrupted(let message):
            if isRecording { finishRecording() }
            resetViewfinder()
            problem = message
            needsSettings = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        case .stopped:
            if isRecording { finishRecording() }
            resetViewfinder()
        }
    }

    private func markReady() {
        firstFrameTimeout?.cancel()
        problem = nil
        ready = true
    }

    private func photograph() {
        busy = true
        beginFinishingTime()
        media.takePhoto { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                Task {
                    do {
                        let file = try await self.store.writePhoto(data)
                        await self.saveCapture(file, isPhoto: true)
                    } catch {
                        self.finished(error.localizedDescription)
                    }
                }
            case .failure(let error):
                self.finished(error.localizedDescription)
            }
        }
    }

    private func beginRecording() {
        do {
            let id = UUID()
            let url = try CaptureStore.newFile(extension: "mov")
            try media.startRecording(to: url, includeAudio: micEnabled) { [weak self] error in
                guard let self, self.recordingID == id else { return }
                self.recordingID = nil
                self.endRecordingUI()
                self.finished(error.localizedDescription)
            }
            recordingID = id
            isRecording = true
            elapsed = 0
            UIApplication.shared.isIdleTimerDisabled = true
            let started = ProcessInfo.processInfo.systemUptime
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    self?.elapsed = floor(ProcessInfo.processInfo.systemUptime - started)
                }
            }
        } catch {
            report(error.localizedDescription)
        }
    }

    private func endRecordingUI() {
        isRecording = false
        clock?.cancel()
        clock = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finishRecording() {
        guard isRecording, let id = recordingID else { return }
        busy = true
        beginFinishingTime()
        endRecordingUI()
        media.stopRecording { [weak self] result in
            guard let self, self.recordingID == id else { return }
            self.recordingID = nil
            switch result {
            case .success(let url):
                Task { await self.saveCapture(url, isPhoto: false) }
            case .failure(let error):
                self.finished(error.localizedDescription)
            }
        }
    }

    private func saveCapture(_ file: URL, isPhoto: Bool) async {
        let canPrompt = foreground && UIApplication.shared.applicationState != .background
        let copied = await store.copyToPhotos(file, isPhoto: isPhoto, canPrompt: canPrompt)
        let item = isPhoto ? "照片" : "影片"
        finished(copied ? "\(item)已儲存到「照片」。" : "\(item)已保存在「檔案」→「我的 iPhone」→「雙鏡」→ Captures。")
    }

    private func finished(_ message: String) {
        busy = false
        endFinishingTime()
        report(message)
    }

    private func report(_ message: String) {
        dismissNotice?.cancel()
        notice = message
        dismissNotice = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
            self?.notice = nil
        }
    }

    private func beginFinishingTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save capture") { [weak self] in
            self?.endFinishingTime()
        }
    }

    private func endFinishingTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private actor CaptureStore {
    static func newFile(extension suffix: String) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("TwinFrame-" + UUID().uuidString).appendingPathExtension(suffix)
    }

    func writePhoto(_ data: Data) throws -> URL {
        let file = try Self.newFile(extension: "jpg")
        try data.write(to: file, options: .atomic)
        return file
    }

    // Keep a local copy until Photos confirms it has imported the complete file.
    func copyToPhotos(_ url: URL, isPhoto: Bool, canPrompt: Bool) async -> Bool {
        var access = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if access == .notDetermined, canPrompt {
            access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard access == .authorized || access == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isPhoto ? .photo : .video, fileURL: url, options: nil)
            }
            try? FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
