import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Consumes a synchronized pair of *upright, unmirrored* portrait camera samples.
/// UI closures are delivered on main, except onPreview, which runs on the media queue.
final class MediaPipeline {
    var onPreview: ((CVPixelBuffer) -> Void)?

    private static let width = 720
    private static let height = 1280
    private static let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    // Core Image has a bottom-left origin. These proportions are relative to the canvas.
    private static let tile = CGRect(
        x: canvas.width * 0.64,
        y: canvas.height * (1 - 0.035 - 0.24),
        width: canvas.width * 0.32,
        height: canvas.height * 0.24
    )

    private let queue = DispatchQueue(label: "DualCam.media", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [.cacheIntermediates: false])
    private lazy var tileMask = Self.roundedMask(in: Self.tile, radius: 17)
    private lazy var tileBorder = Self.roundedMask(in: Self.tile.insetBy(dx: -2, dy: -2), radius: 19)
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.72)])

    private var previewPool: CVPixelBufferPool?
    private var latestFrame: CVPixelBuffer?
    private var latestFrameUptime: TimeInterval = 0
    private var frontPrimary = false
    private var movie: Movie?
    private var finishing = false

    func setFrontPrimary(_ value: Bool) {
        queue.sync {
            if value != frontPrimary {
                frontPrimary = value
                latestFrame = nil
            }
        }
    }

    func consumeVideo(back: CMSampleBuffer, front: CMSampleBuffer) {
        // Backpressure stays at the capture delegate, which can drop late frames. Avoid
        // queueing camera buffers asynchronously because that can exhaust both sensors' pools.
        queue.sync {
            autoreleasepool {
                guard CMSampleBufferDataIsReady(back), CMSampleBufferDataIsReady(front),
                      let backBuffer = CMSampleBufferGetImageBuffer(back),
                      let frontBuffer = CMSampleBufferGetImageBuffer(front) else { return }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(back)
                let otherTime = CMSampleBufferGetPresentationTimeStamp(front)
                guard timestamp.isNumeric, otherTime.isNumeric,
                      CMTimeAbsoluteValue(timestamp - otherTime) <= CMTime(value: 1, timescale: 12),
                      let destination = nextBuffer() else { return }

                let rear = CIImage(cvPixelBuffer: backBuffer)
                let selfie = CIImage(cvPixelBuffer: frontBuffer).oriented(.upMirrored)
                let full = Self.aspectFill(frontPrimary ? selfie : rear, into: Self.canvas)
                let inset = Self.aspectFill(frontPrimary ? rear : selfie, into: Self.tile)
                let composed = inset.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: tileBorder.composited(over: full),
                    kCIInputMaskImageKey: tileMask
                ]).cropped(to: Self.canvas)

                context.render(composed, to: destination, bounds: Self.canvas, colorSpace: colorSpace)
                latestFrame = destination
                latestFrameUptime = ProcessInfo.processInfo.systemUptime
                if let movie = movie {
                    do {
                        try movie.appendVideo(destination, at: timestamp, duration: CMSampleBufferGetDuration(back))
                    } catch {
                        fail(movie, error: error)
                    }
                }
                onPreview?(destination)
            }
        }
    }

    func consumeAudio(_ sample: CMSampleBuffer) {
        queue.sync {
            guard let movie = movie else { return }
            do {
                try movie.appendAudio(sample)
            } catch {
                fail(movie, error: error)
            }
        }
    }

    func takePhoto(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            let result: Result<Data, Error> = autoreleasepool {
                guard let frame = self.latestFrame,
                      ProcessInfo.processInfo.systemUptime - self.latestFrameUptime <= 1 else {
                    return .failure(PipelineError.noFrame)
                }
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let data = self.context.jpegRepresentation(
                    of: CIImage(cvPixelBuffer: frame), colorSpace: self.colorSpace, options: [quality: 0.94]
                ) else { return .failure(PipelineError.photo) }
                return .success(data)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func startRecording(to url: URL, includeAudio: Bool, onFailure: @escaping (Error) -> Void) throws {
        try queue.sync {
            guard movie == nil, !finishing else { throw PipelineError.busy }
            movie = try Movie(url: url, width: Self.width, height: Self.height,
                              includeAudio: includeAudio, onFailure: onFailure)
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.sync {
            guard let current = movie else {
                DispatchQueue.main.async { completion(.failure(PipelineError.noMovie)) }
                return
            }
            movie = nil
            guard current.didAppendVideo, current.writer.status == .writing else {
                let error = current.writer.error ?? PipelineError.noFramesRecorded
                current.discard()
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            finishing = true
            current.finish {
                self.queue.async {
                    self.finishing = false
                    let result: Result<URL, Error>
                    if current.writer.status == .completed {
                        result = .success(current.url)
                    } else {
                        let error = current.writer.error ?? PipelineError.movie
                        current.discard()
                        result = .failure(error)
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    private func fail(_ current: Movie, error: Error) {
        movie = nil
        current.discard()
        DispatchQueue.main.async { current.onFailure(error) }
    }

    private func nextBuffer() -> CVPixelBuffer? {
        if previewPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &previewPool)
        }
        guard let pool = previewPool else { return nil }
        // Drop a frame if the preview or encoder is holding too many buffers.
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    private static func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY
        ))
        return centered.cropped(to: rect)
    }

    private static func roundedMask(in rect: CGRect, radius: CGFloat) -> CIImage {
        let rounded = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
        // Supply explicit transparent pixels around the mask for Core Image's blend kernel.
        return rounded.composited(over: CIImage(color: .clear)).cropped(to: canvas)
    }
}

private enum PipelineError: LocalizedError {
    case noFrame, noMovie, noFramesRecorded, busy, photo, movie, audio, existingFile

    var errorDescription: String? {
        switch self {
        case .noFrame: return "正在等候雙鏡頭畫面，請稍後再拍。"
        case .noMovie: return "目前沒有正在錄製的影片。"
        case .noFramesRecorded: return "還未錄到畫面。請等候預覽出現後再錄製。"
        case .busy: return "上一段影片正在處理中。"
        case .photo: return "無法建立照片。"
        case .movie: return "無法寫入影片。請確認手機有足夠空間。"
        case .audio: return "無法建立錄音音軌。"
        case .existingFile: return "錄影檔名已被使用。請重新開始錄製。"
        }
    }
}

private final class Movie {
    let url: URL
    let writer: AVAssetWriter
    let onFailure: (Error) -> Void
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastVideoDuration = CMTime(value: 1, timescale: 30)
    private var lastAudioTime: CMTime?
    var didAppendVideo: Bool { lastVideoTime != nil }

    init(url: URL, width: Int, height: Int, includeAudio: Bool, onFailure: @escaping (Error) -> Void) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.existingFile }
        self.url = url
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_500_000, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            audio = input
        } else {
            audio = nil
        }

        do {
            guard writer.canAdd(video) else { throw PipelineError.movie }
            writer.add(video)
            if let audio = audio {
                guard writer.canAdd(audio) else { throw PipelineError.audio }
                writer.add(audio)
            }
            guard writer.startWriting() else { throw writer.error ?? PipelineError.movie }
        } catch {
            discard()
            throw error
        }
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        guard writer.status == .writing else { throw writer.error ?? PipelineError.movie }
        guard lastVideoTime.map({ time > $0 }) ?? true else { return }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard video.isReadyForMoreMediaData else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? PipelineError.movie }
        if duration.isNumeric && duration > .zero {
            lastVideoDuration = duration
        }
        lastVideoTime = time
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard let audio = audio, let start = startTime, didAppendVideo, CMSampleBufferDataIsReady(sample) else { return }
        guard writer.status == .writing else { throw writer.error ?? PipelineError.movie }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, time >= start, lastAudioTime.map({ time > $0 }) ?? true,
              audio.isReadyForMoreMediaData else { return }
        guard audio.append(sample) else { throw writer.error ?? PipelineError.audio }
        lastAudioTime = time
    }

    func finish(_ completion: @escaping () -> Void) {
        if let time = lastVideoTime {
            writer.endSession(atSourceTime: time + lastVideoDuration)
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
