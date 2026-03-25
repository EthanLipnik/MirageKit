//
//  VideoEncoder+Encoding.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

enum EncodedFrameExtractionError: Error, Equatable, Sendable {
    case emptyData
    case copyFailed(status: OSStatus, totalLength: Int, pointerStatus: OSStatus, contiguousLength: Int)

    var logSummary: String {
        switch self {
        case .emptyData:
            "sample buffer data is empty"
        case let .copyFailed(status, totalLength, pointerStatus, contiguousLength):
            "copy failed status=\(status), totalLength=\(totalLength), pointerStatus=\(pointerStatus), contiguousLength=\(contiguousLength)"
        }
    }
}

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

extension VideoEncoder {
    /// Returns `true` if the encoder produced at least one valid output frame.
    @discardableResult
    func preheat() async throws -> Bool {
        guard let session = compressionSession else {
            MirageLogger.error(.encoder, "Cannot preheat: no compression session")
            return false
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
            return false
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

        // Track how many preheat frames produce valid encoded output
        let validOutputCount = Locked<Int>(0)
        let callbackErrorCount = Locked<Int>(0)
        let lastCallbackStatus = Locked<OSStatus>(noErr)
        var submittedCount = 0

        for i in 0 ..< preheatFrameCount {
            let pts = CMTime(value: CMTimeValue(i), timescale: timescale)
            let duration = CMTime(value: 1, timescale: timescale)

            var properties: [CFString: Any] = [:]
            if i == 0 {
                // First frame must be keyframe
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
                MirageLogger.error(.encoder, "Preheat encode failed at frame \(i): \(encodeStatus)")
                break
            }
            submittedCount += 1
        }

        // VTCompressionSessionCompleteFrames is synchronous — all callbacks
        // will have fired by the time it returns.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        // Reset frame counter so first real frame is frame 0
        frameNumber = 0
        forceNextKeyframe = true // First real frame should be keyframe

        let preheatDuration = (CFAbsoluteTimeGetCurrent() - preheatStartTime) * 1000
        let valid = validOutputCount.withLock { $0 }
        let errors = callbackErrorCount.withLock { $0 }

        if valid == 0 && submittedCount > 0 {
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
            isProRes: isProRes,
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

            guard status == noErr, let sampleBuffer else {
                if status != noErr {
                    self.recordCallbackFailure(frameNumber: info.frameNumber, status: status)
                }
                return
            }

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
            if info.frameNumber < 3 {
                Task(priority: .utility) {
                    await self.refreshHardwareStatusIfNeeded(
                        reason: "first_output_frame_\(info.frameNumber)"
                    )
                }
            }

            // Check if keyframe
            let isKeyframe = Self.isKeyframe(sampleBuffer)

            // Extract encoded data
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            let rawFrameData: Data
            do {
                rawFrameData = try Self.extractEncodedFrameData(from: dataBuffer)
            } catch let extractionError as EncodedFrameExtractionError {
                let now = CFAbsoluteTimeGetCurrent()
                if self.shouldLogBitstreamFailure(at: now) {
                    MirageLogger
                        .error(
                            .encoder,
                            "Dropping frame \(info.frameNumber): failed to extract encoded bytes (\(extractionError.logSummary))"
                        )
                }
                Task { [weak self] in
                    await self?.scheduleRecoveryKeyframe(reason: "encoded-frame-extraction")
                }
                return
            } catch {
                let now = CFAbsoluteTimeGetCurrent()
                if self.shouldLogBitstreamFailure(at: now) {
                    MirageLogger.error(
                        .encoder,
                        "Dropping frame \(info.frameNumber): unexpected extraction failure (\(error))"
                    )
                }
                Task { [weak self] in
                    await self?.scheduleRecoveryKeyframe(reason: "encoded-frame-extraction")
                }
                return
            }

            var data: Data

            if info.isProRes {
                // ProRes frames are self-contained — no NAL units or parameter sets
                data = rawFrameData
            } else {
                let validation = Self.validateLengthPrefixedHEVCBitstream(rawFrameData)
                guard validation.isValid else {
                    let now = CFAbsoluteTimeGetCurrent()
                    if self.shouldLogBitstreamFailure(at: now) {
                        MirageLogger
                            .error(
                                .encoder,
                                "Dropping frame \(info.frameNumber): invalid AVCC payload (\(validation.logSummary))"
                            )
                    }
                    Task { [weak self] in
                        await self?.scheduleRecoveryKeyframe(reason: "invalid-avcc")
                    }
                    return
                }

                data = rawFrameData

                // For keyframes, prepend VPS/SPS/PPS with Annex B start codes
                if isKeyframe {
                    // Extract parameter sets for keyframes
                    if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                        if let chromaSampling = Self.chromaSampling(from: formatDesc) {
                            Task(priority: .utility) {
                                await self.recordEncodedChromaSampling(chromaSampling)
                            }
                        }
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

    @discardableResult
    nonisolated static func extractEncodedFrameData(from dataBuffer: CMBlockBuffer) throws -> Data {
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { throw EncodedFrameExtractionError.emptyData }

        var contiguousLength = 0
        var totalLengthOut = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLengthOut,
            dataPointerOut: &dataPointer
        )

        if pointerStatus == noErr,
           totalLengthOut == totalLength,
           contiguousLength == totalLength,
           let dataPointer {
            return Data(bytes: dataPointer, count: totalLength)
        }

        var copiedData = Data(count: totalLength)
        let copyStatus = copiedData.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -12700 }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }

        guard copyStatus == noErr else {
            throw EncodedFrameExtractionError.copyFailed(
                status: copyStatus,
                totalLength: totalLength,
                pointerStatus: pointerStatus,
                contiguousLength: contiguousLength
            )
        }

        return copiedData
    }

    nonisolated func recordCallbackFailure(frameNumber: UInt64, status: OSStatus) {
        bitstreamFailureLogLock.lock()
        callbackFailureCount += 1
        let count = callbackFailureCount
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog = lastCallbackFailureLogTime == 0 ||
            now - lastCallbackFailureLogTime >= Self.bitstreamFailureLogCooldown
        if shouldLog { lastCallbackFailureLogTime = now }
        bitstreamFailureLogLock.unlock()

        if shouldLog {
            MirageLogger.error(
                .encoder,
                "Encoder callback failure: frame=\(frameNumber), status=\(status), totalFailures=\(count)"
            )
        }
    }

    nonisolated func getAndResetCallbackFailureCount() -> UInt64 {
        bitstreamFailureLogLock.lock()
        let count = callbackFailureCount
        callbackFailureCount = 0
        bitstreamFailureLogLock.unlock()
        return count
    }

    nonisolated func shouldLogBitstreamFailure(at now: CFAbsoluteTime) -> Bool {
        bitstreamFailureLogLock.lock()
        defer { bitstreamFailureLogLock.unlock() }
        if lastBitstreamFailureLogTime > 0,
           now - lastBitstreamFailureLogTime < Self.bitstreamFailureLogCooldown {
            return false
        }
        lastBitstreamFailureLogTime = now
        return true
    }

    func scheduleRecoveryKeyframe(reason: String) {
        guard !forceNextKeyframe else { return }
        forceNextKeyframe = true
        MirageLogger.encoder("Scheduling recovery keyframe (\(reason))")
    }
}

#endif
