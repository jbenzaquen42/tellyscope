import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

struct ScreenRecordingBackupFrame: Sendable {
    let url: URL
    let elapsed: TimeInterval
}

enum ScreenRecordingRecovery {
    private static let signatureWidth = 28
    private static let signatureHeight = 28
    private static let meaningfulChangeThreshold = 0.018

    static func writeBackupFrame(
        pngData: Data,
        index: Int,
        elapsed: TimeInterval,
        to directory: URL
    ) -> ScreenRecordingBackupFrame? {
        guard let image = UIImage(data: pngData),
              let normalized = resizedForBackup(image),
              let data = normalized.jpegData(compressionQuality: 0.72) else {
            return nil
        }

        let milliseconds = max(0, Int((elapsed * 1_000).rounded()))
        let url = directory.appendingPathComponent(
            String(format: "%04d-%08d.jpg", index, milliseconds)
        )
        do {
            try data.write(to: url, options: .atomic)
            return ScreenRecordingBackupFrame(url: url, elapsed: elapsed)
        } catch {
            return nil
        }
    }

    static func backupFramesHaveMeaningfulChange(
        _ frames: [ScreenRecordingBackupFrame]
    ) -> Bool {
        let signatures = frames.compactMap {
            UIImage(contentsOfFile: $0.url.path)?.cgImage.flatMap(visualSignature)
        }
        return signaturesHaveMeaningfulChange(signatures)
    }

    static func videoHasMeaningfulChange(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let assetDuration = try? await asset.load(.duration) else {
            return false
        }
        let duration = CMTimeGetSeconds(assetDuration)
        guard duration.isFinite, duration > 0.4 else { return false }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: 0.12,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: 0.12,
            preferredTimescale: 600
        )

        let fractions: [Double] = [0.04, 0.16, 0.32, 0.50, 0.68, 0.84, 0.96]
        let signatures = fractions.compactMap { fraction -> [UInt8]? in
            let requestedTime = CMTime(
                seconds: duration * fraction,
                preferredTimescale: 600
            )
            guard let image = try? generator.copyCGImage(
                at: requestedTime,
                actualTime: nil
            ) else {
                return nil
            }
            return visualSignature(image)
        }
        return signaturesHaveMeaningfulChange(signatures)
    }

    static func makeFallbackVideo(
        from frames: [ScreenRecordingBackupFrame],
        duration: TimeInterval,
        at outputURL: URL
    ) async throws {
        let orderedFrames = frames.sorted { $0.elapsed < $1.elapsed }
        guard let firstFrame = orderedFrames.first,
              let firstImage = UIImage(contentsOfFile: firstFrame.url.path),
              let firstCGImage = firstImage.cgImage else {
            throw ScreenRecordingRecoveryError.noFrames
        }

        try? FileManager.default.removeItem(at: outputURL)
        let videoSize = normalizedVideoSize(for: firstCGImage)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(input) else {
            throw ScreenRecordingRecoveryError.cannotCreateWriter
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ScreenRecordingRecoveryError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: .zero)

        var finalPixelBuffer: CVPixelBuffer?
        var lastPresentationTime = CMTime.zero

        for (index, frame) in orderedFrames.enumerated() {
            guard let image = UIImage(contentsOfFile: frame.url.path)?.cgImage,
                  let pixelBuffer = makePixelBuffer(
                    from: image,
                    size: videoSize,
                    pool: adaptor.pixelBufferPool
                  ) else {
                continue
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            // The Android fallback sampler may slow down under load. Map the
            // frames uniformly onto the duration the user selected instead of
            // leaking that device-side delay into a longer exported movie.
            let elapsed = duration * Double(index) / Double(orderedFrames.count)
            let presentationTime = CMTime(
                seconds: elapsed,
                preferredTimescale: 600
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ScreenRecordingRecoveryError.cannotAppendFrame
            }
            finalPixelBuffer = pixelBuffer
            lastPresentationTime = presentationTime
        }

        guard let finalPixelBuffer else {
            throw ScreenRecordingRecoveryError.noFrames
        }
        let requestedEnd = CMTime(
            seconds: max(0.5, duration),
            preferredTimescale: 600
        )
        if CMTimeCompare(requestedEnd, lastPresentationTime) > 0 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(
                finalPixelBuffer,
                withPresentationTime: requestedEnd
            ) else {
                throw writer.error ?? ScreenRecordingRecoveryError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ScreenRecordingRecoveryError.cannotFinish
        }
    }

    private static func resizedForBackup(_ image: UIImage) -> UIImage? {
        let maximumDimension: CGFloat = 1_600
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(
            1,
            maximumDimension / max(sourceSize.width, sourceSize.height)
        )
        let targetSize = CGSize(
            width: max(2, (sourceSize.width * scale).rounded()),
            height: max(2, (sourceSize.height * scale).rounded())
        )
        if scale == 1 {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image {
            _ in image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func visualSignature(_ image: CGImage) -> [UInt8]? {
        let insetX = max(1, Int((Double(image.width) * 0.12).rounded()))
        let insetY = max(1, Int((Double(image.height) * 0.12).rounded()))
        let cropRect = CGRect(
            x: insetX,
            y: insetY,
            width: max(1, image.width - insetX * 2),
            height: max(1, image.height - insetY * 2)
        )
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        var bytes = [UInt8](
            repeating: 0,
            count: signatureWidth * signatureHeight * 4
        )
        guard let context = CGContext(
            data: &bytes,
            width: signatureWidth,
            height: signatureHeight,
            bitsPerComponent: 8,
            bytesPerRow: signatureWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(
            cropped,
            in: CGRect(
                x: 0,
                y: 0,
                width: signatureWidth,
                height: signatureHeight
            )
        )

        var signature: [UInt8] = []
        signature.reserveCapacity(signatureWidth * signatureHeight * 3)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            signature.append(bytes[offset])
            signature.append(bytes[offset + 1])
            signature.append(bytes[offset + 2])
        }
        return signature
    }

    private static func signaturesHaveMeaningfulChange(
        _ signatures: [[UInt8]]
    ) -> Bool {
        guard signatures.count > 1 else { return false }
        for firstIndex in signatures.indices.dropLast() {
            for secondIndex in signatures.indices where secondIndex > firstIndex {
                let first = signatures[firstIndex]
                let second = signatures[secondIndex]
                guard first.count == second.count, !first.isEmpty else { continue }
                let difference = zip(first, second).reduce(0.0) { result, pair in
                    result + Double(abs(Int(pair.0) - Int(pair.1)))
                } / Double(first.count) / 255
                if difference >= meaningfulChangeThreshold {
                    return true
                }
            }
        }
        return false
    }

    private static func normalizedVideoSize(for image: CGImage) -> CGSize {
        let maximumDimension: CGFloat = 1_600
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scale = min(
            1,
            maximumDimension / max(sourceWidth, sourceHeight)
        )
        let width = max(2, Int((sourceWidth * scale).rounded()) / 2 * 2)
        let height = max(2, Int((sourceHeight * scale).rounded()) / 2 * 2)
        return CGSize(width: width, height: height)
    }

    private static func makePixelBuffer(
        from image: CGImage,
        size: CGSize,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &pixelBuffer
            )
        } else {
            status = CVPixelBufferCreate(
                nil,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32ARGB,
                [
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ] as CFDictionary,
                &pixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            size.width / imageSize.width,
            size.height / imageSize.height
        )
        let drawSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let drawRect = CGRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        return pixelBuffer
    }
}

private enum ScreenRecordingRecoveryError: LocalizedError {
    case noFrames
    case cannotCreateWriter
    case cannotAppendFrame
    case cannotFinish

    var errorDescription: String? {
        switch self {
        case .noFrames:
            L10n.string("text.screen_recording_recovery_has_no_frames")
        case .cannotCreateWriter:
            L10n.string("text.screen_recording_recovery_could_not_start")
        case .cannotAppendFrame:
            L10n.string("text.screen_recording_recovery_could_not_write_a_frame")
        case .cannotFinish:
            L10n.string("text.screen_recording_recovery_could_not_finish")
        }
    }
}
