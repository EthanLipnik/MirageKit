//
//  HEVCEncoder+Encoding.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox

#if os(macOS)
import ScreenCaptureKit

enum EncodeSkipReason: String {
    case dimensionUpdate = "dimension update"
    case encoderInactive = "encoder inactive"
    case noSession = "no session"
    case queueFull = "queue full"
}

enum EncodeAdmission {
    case accepted
    case skipped(EncodeSkipReason)
}

extension HEVCEncoder {
    func preheat() async throws {
        guard let session = compressionSession else {
            MirageLogger.error(.encoder, "Cannot preheat: no compression session")
            return
        }

        let preheatStartTime = CFAbsoluteTimeGetCurrent()
        let preheatFrameCount = 10 // Enough frames to warm up rate control and hardware

        // Create a dummy pixel buffer at session dimensions
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
            return
        }

        // Fill with gray (neutral content for rate control)
        CVPixelBufferLockBaseAddress(buffer, [])
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
        CVPixelBufferUnlockBaseAddress(buffer, [])

        MirageLogger.encoder("Pre-heating encoder with \(preheatFrameCount) dummy frames...")

        let timescale = CMTimeScale(max(1, configuration.targetFrameRate))

        // Encode dummy frames and discard output
        for i in 0 ..< preheatFrameCount {
            let pts = CMTime(value: CMTimeValue(i), timescale: timescale)
            let duration = CMTime(value: 1, timescale: timescale)

            var properties: [CFString: Any] = [:]
            if i == 0 {
                // First frame must be keyframe
                properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
            }

            // Encode with callback that discards output
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: buffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
                infoFlagsOut: nil
            ) { _, _, _ in
                // Discard output - we only care about warming up the encoder
            }

            if encodeStatus != noErr {
                MirageLogger.error(.encoder, "Preheat encode failed at frame \(i): \(encodeStatus)")
                break
            }
        }

        // Ensure all preheat frames are flushed
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        // Reset frame counter so first real frame is frame 0
        frameNumber = 0
        forceNextKeyframe = true // First real frame should be keyframe

        let preheatDuration = (CFAbsoluteTimeGetCurrent() - preheatStartTime) * 1000
        MirageLogger.timing("Encoder pre-heat complete: \(String(format: "%.1f", preheatDuration))ms")
    }

    func startEncoding(
        onEncodedFrame: @escaping (Data, Bool, CMTime) -> Void,
        onFrameComplete: @escaping @Sendable () -> Void
    ) {
        encodedFrameHandler = onEncodedFrame
        frameCompletionHandler = onFrameComplete
        isEncoding = true
    }

    func stopEncoding() {
        isEncoding = false
        encodedFrameHandler = nil
        frameCompletionHandler = nil

        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
    }

    func encodeFrame(_ frame: CapturedFrame, forceKeyframe: Bool = false) async throws -> EncodeAdmission {
        let encodeStartTime = CFAbsoluteTimeGetCurrent() // Timing: encode start

        // Drop frames during dimension update to prevent deadlock
        guard !isUpdatingDimensions else {
            MirageLogger.encoder("Skipping encode: dimension update in progress")
            return .skipped(.dimensionUpdate)
        }
        guard isEncoding else {
            MirageLogger.encoder("Skipping encode: encoder not active")
            return .skipped(.encoderInactive)
        }
        guard let session = compressionSession else {
            MirageLogger.encoder("Skipping encode: no compression session")
            return .skipped(.noSession)
        }

        let pixelBuffer = frame.pixelBuffer

        let bufferPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if !didLogPixelFormat {
            let bufferFourCC = Self.fourCCString(bufferPixelFormat)
            let sessionFourCC = Self.fourCCString(pixelFormatType)
            if bufferPixelFormat != pixelFormatType {
                MirageLogger.error(
                    .encoder,
                    "Pixel format mismatch. Buffer=\(bufferFourCC) (\(bufferPixelFormat)) session=\(sessionFourCC) (\(pixelFormatType))"
                )
            } else {
                MirageLogger.encoder("Pixel format match: \(bufferFourCC) (\(bufferPixelFormat))")
            }
            didLogPixelFormat = true
        }

        guard reserveEncoderSlot() else {
            MirageLogger.encoder("Skipping encode: encoder queue full")
            return .skipped(.queueFull)
        }

        let presentationTime = frame.presentationTime
        let duration = frame.duration

        // Force keyframe on first frame or when requested
        let isFirstFrame = frameNumber == 0
        var properties: [CFString: Any] = [:]
        let isKeyframe = forceKeyframe || forceNextKeyframe || isFirstFrame
        if isKeyframe {
            MirageLogger
                .encoder(
                    "Forcing keyframe (first=\(isFirstFrame), forceNext=\(forceNextKeyframe), param=\(forceKeyframe))"
                )
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
            forceNextKeyframe = false
        }

        // Capture session version for this frame
        let currentSessionVersion = sessionVersion
        let encodeInfo = EncodeInfo(
            frameNumber: frameNumber,
            handler: encodedFrameHandler,
            encodeStartTime: encodeStartTime,
            sessionVersion: currentSessionVersion,
            performanceTracker: performanceTracker,
            completion: frameCompletionHandler,
            getCurrentVersion: { [weak self] in self?.sessionVersion ?? 0 }
        )
        frameNumber += 1

        let opaqueInfo = Unmanaged.passRetained(encodeInfo).toOpaque()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            let info = Unmanaged<EncodeInfo>.fromOpaque(opaqueInfo).takeRetainedValue()
            defer {
                self.releaseEncoderSlot()
                info.completion?()
            }

            guard status == noErr, let sampleBuffer else { return }

            if infoFlags.contains(.frameDropped) {
                MirageLogger.debug(.encoder, "VT dropped frame \(info.frameNumber)")
                return
            }

            // CRITICAL: Discard frames from old sessions during dimension transitions
            // This prevents sending P-frames encoded at old dimensions after a resize
            guard info.isSessionCurrent else {
                MirageLogger
                    .encoder(
                        "Discarding frame \(info.frameNumber) from old session (version \(info.sessionVersion) != \(info.getCurrentVersion()))"
                    )
                return
            }

            // Timing: calculate encoding duration
            let encodeEndTime = CFAbsoluteTimeGetCurrent()
            let encodingDuration = (encodeEndTime - info.encodeStartTime) * 1000 // ms
            info.performanceTracker?.record(durationMs: encodingDuration)

            // Check if keyframe
            let isKeyframe = Self.isKeyframe(sampleBuffer)

            // Extract encoded data
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )

            guard let pointer = dataPointer else { return }

            var data = Data(bytes: pointer, count: length)

            // For keyframes, prepend VPS/SPS/PPS with Annex B start codes
            if isKeyframe {
                // Extract parameter sets for keyframes
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    if let parameterSets = Self.extractParameterSets(from: formatDesc) {
                        var framed = Data(capacity: 4 + parameterSets.count + data.count)
                        var parameterSetLength = UInt32(parameterSets.count).bigEndian
                        withUnsafeBytes(of: &parameterSetLength) { framed.append(contentsOf: $0) }
                        framed.append(parameterSets)
                        framed.append(data)
                        data = framed
                        MirageLogger.encoder("Prepended \(parameterSets.count) bytes of parameter sets")
                    } else {
                        MirageLogger.error(.encoder, "Failed to extract parameter sets from format description")
                    }
                } else {
                    MirageLogger.error(.encoder, "No format description available for keyframe")
                }
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Log timing for every frame (first 10, then every 60th)
            if info.frameNumber < 10 || info.frameNumber % 60 == 0 || isKeyframe {
                let bytesKB = Double(data.count) / 1024.0
                MirageLogger.debug(
                    .timing,
                    "Encoder frame \(info.frameNumber): \(String(format: "%.2f", encodingDuration))ms, \(String(format: "%.1f", bytesKB))KB\(isKeyframe ? " (keyframe)" : "")"
                )
            }

            info.handler?(data, isKeyframe, pts)
        }

        if status != noErr {
            Unmanaged<EncodeInfo>.fromOpaque(opaqueInfo).release()
            encodeInfo.completion?()
            releaseEncoderSlot()
            throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        return .accepted
    }
}

#endif
