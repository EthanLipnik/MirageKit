//
//  VideoEncoder+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
extension VideoEncoder {
    /// Returns `true` when the active compression session can produce valid encoded output.
    func preheat() async throws -> Bool {
        guard let session = compressionSession else {
            MirageLogger.error(.encoder, "Cannot preheat: no compression session")
            return false
        }

        let preheatStartTime = CFAbsoluteTimeGetCurrent()
        let preheatFrameCount = 10

        var pixelBuffer: CVPixelBuffer?
        let targetWidth = max(1, currentWidth)
        let targetHeight = max(1, currentHeight)
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth, targetHeight,
            pixelFormatType,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &pixelBuffer
        )

        guard status == noErr, let buffer = pixelBuffer else {
            MirageLogger.error(.encoder, "Failed to create preheat buffer: \(status)")
            return false
        }

        fillPreheatBuffer(buffer)

        MirageLogger.encoder("Pre-heating encoder with \(preheatFrameCount) dummy frames...")

        let timescale = CMTimeScale(max(1, configuration.targetFrameRate))
        let validOutputCount = Locked<Int>(0)
        let callbackErrorCount = Locked<Int>(0)
        let lastCallbackStatus = Locked<OSStatus>(noErr)
        var submittedCount = 0

        for frameIndex in 0 ..< preheatFrameCount {
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
            let duration = CMTime(value: 1, timescale: timescale)

            var properties: [CFString: Any] = [:]
            if frameIndex == 0 {
                properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
            }

            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: buffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
                infoFlagsOut: nil
            ) { cbStatus, infoFlags, sampleBuffer in
                guard cbStatus == noErr,
                      !infoFlags.contains(.frameDropped),
                      let sampleBuffer,
                      CMSampleBufferGetDataBuffer(sampleBuffer) != nil else {
                    callbackErrorCount.withLock { $0 += 1 }
                    if cbStatus != noErr {
                        lastCallbackStatus.withLock { $0 = cbStatus }
                    }
                    return
                }
                validOutputCount.withLock { $0 += 1 }
            }

            if encodeStatus != noErr {
                MirageLogger.error(.encoder, "Preheat encode failed at frame \(frameIndex): \(encodeStatus)")
                break
            }
            submittedCount += 1
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        frameNumber = 0
        forceNextKeyframe = true

        let preheatDuration = (CFAbsoluteTimeGetCurrent() - preheatStartTime) * 1000
        let valid = validOutputCount.withLock { $0 }
        let errors = callbackErrorCount.withLock { $0 }

        if valid == 0, submittedCount > 0 {
            let lastStatus = lastCallbackStatus.withLock { $0 }
            MirageLogger.error(
                .encoder,
                "Encoder pre-heat FAILED: 0/\(submittedCount) frames produced valid output (\(errors) callback errors, lastStatus=\(lastStatus)), format=\(activePixelFormat.displayName), \(currentWidth)x\(currentHeight)"
            )
            return false
        }

        MirageLogger.timing(
            "Encoder pre-heat complete: \(String(format: "%.1f", preheatDuration))ms, valid=\(valid)/\(submittedCount)"
        )
        return true
    }

    /// Registers output callbacks and admits future frames into the active compression session.
    func startEncoding(
        onEncodedFrame: @escaping @Sendable (Data, Bool, CMTime, @escaping @Sendable () -> Void) -> Void,
        onFrameComplete: @escaping @Sendable () -> Void
    ) {
        encodedFrameHandler = onEncodedFrame
        frameCompletionHandler = onFrameComplete
        isEncoding = true
    }

    /// Invalidates the active compression session and clears frame callbacks.
    func stopEncoding() {
        sessionVersion &+= 1
        resetEncoderSlots()
        isEncoding = false
        encodedFrameHandler = nil
        frameCompletionHandler = nil

        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
    }

    private func fillPreheatBuffer(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if CVPixelBufferIsPlanar(buffer) {
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            for plane in 0 ..< planeCount {
                guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(baseAddress, 0x80, bytesPerRow * height)
            }
        } else if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            memset(baseAddress, 0x80, bytesPerRow * height)
        }
    }
}
#endif
