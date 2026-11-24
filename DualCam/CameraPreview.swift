import AVFoundation
import SwiftUI
import UIKit

// Keep only the newest frame when the display is slower than the camera.
final class PreviewSurface {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var deliveryScheduled = false
    @MainActor private weak var host: PreviewView?
    @MainActor private var format: CMVideoFormatDescription?
    @MainActor private var waitingForFirstFrame = true
    @MainActor var onFirstFrame: (() -> Void)?

    func submit(_ frame: CVPixelBuffer) {
        lock.lock()
        latest = frame
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.displayLatest() }
        }
    }

    @MainActor func attach(to view: PreviewView) {
        host = view
    }

    @MainActor func reset() {
        lock.lock()
        latest = nil
        lock.unlock()
        host?.display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        waitingForFirstFrame = true
    }

    @MainActor private func displayLatest() {
        lock.lock()
        let image = latest
        latest = nil
        deliveryScheduled = false
        lock.unlock()
        guard let image, let host else { return }
        let renderer = host.display.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescriptionOut: &format
            ) == noErr else { return }
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let flags = (attachments as NSArray).firstObject as? NSMutableDictionary {
            flags[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(sample)
        if waitingForFirstFrame {
            waitingForFirstFrame = false
            onFirstFrame?()
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct CameraPreview: UIViewRepresentable {
    let surface: PreviewSurface

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.display.videoGravity = .resizeAspect
        surface.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        surface.attach(to: uiView)
    }
}
