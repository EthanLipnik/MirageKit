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

/// Failure while extracting encoded bytes from a VideoToolbox sample buffer.
enum EncodedFrameExtractionError: Error, Equatable {
    /// The sample buffer did not contain encoded byte data.
    case emptyData

    /// `CMBlockBuffer` could not provide a contiguous encoded payload.
    case copyFailed(status: OSStatus, totalLength: Int, pointerStatus: OSStatus, contiguousLength: Int)

    /// Short diagnostic text for frame-drop logging.
    var logSummary: String {
        switch self {
        case .emptyData:
            "sample buffer data is empty"
        case let .copyFailed(status, totalLength, pointerStatus, contiguousLength):
            "copy failed status=\(status), totalLength=\(totalLength), pointerStatus=\(pointerStatus), contiguousLength=\(contiguousLength)"
        }
    }
}

/// Reason a captured frame was skipped before encoder submission.
enum EncodeSkipReason: String {
    /// The frame was superseded by a pending stream dimension update.
    case dimensionUpdate = "dimension update"

    /// The encoder has been deactivated.
    case encoderInactive = "encoder inactive"

    /// No active VideoToolbox compression session is available.
    case noSession = "no session"

    /// The encoder in-flight limit is already full.
    case queueFull = "queue full"
}

/// Admission result for a captured frame entering the encoder.
enum EncodeAdmission {
    /// The frame was submitted to VideoToolbox.
    case accepted

    /// The frame was intentionally skipped before submission.
    case skipped(EncodeSkipReason)
}

/// Sendable wrapper for the retained encode-info pointer passed through VideoToolbox callbacks.
private struct SendableEncodeInfoToken: @unchecked Sendable {
    /// Raw pointer retained until the asynchronous encode callback consumes it.
    let rawPointer: UnsafeMutableRawPointer
}

extension VideoEncoder {
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
            encodedOutputTelemetry: encodedOutputTelemetry,
            completion: frameCompletionHandler,
            isProRes: isProRes,
            retainedSampleBuffer: frame.backingSampleBuffer,
            currentSessionVersion: { [weak self] in self?.sessionVersion ?? 0 }
        )
        frameNumber += 1

        let encodeInfoToken = SendableEncodeInfoToken(
            rawPointer: Unmanaged.passRetained(encodeInfo).toOpaque()
        )

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            let info = Unmanaged<EncodeInfo>.fromOpaque(encodeInfoToken.rawPointer).takeRetainedValue()
            var didTransferCompletion = false
            defer {
                self.releaseEncoderSlot()
                if !didTransferCompletion {
                    info.completion?()
                }
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

            // Dimension changes invalidate queued frames from earlier compression sessions.
            let currentSessionVersion = info.currentSessionVersion()
            guard info.sessionVersion == currentSessionVersion else {
                MirageLogger
                    .encoder(
                        "Discarding frame \(info.frameNumber) from old session (version \(info.sessionVersion) != \(currentSessionVersion))"
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

            if info.frameNumber < 10 || isKeyframe {
                let bytesKB = Double(data.count) / 1024.0
                MirageLogger.debug(
                    .timing,
                    "Encoder frame \(info.frameNumber): \(String(format: "%.2f", encodingDuration))ms, \(String(format: "%.1f", bytesKB))KB\(isKeyframe ? " (keyframe)" : "")"
                )
            }

            info.encodedOutputTelemetry?.recordFrame(byteCount: data.count, isKeyframe: isKeyframe)
            if let handler = info.handler {
                didTransferCompletion = true
                handler(data, isKeyframe, pts) {
                    info.completion?()
                }
            }
        }

        if status != noErr {
            Unmanaged<EncodeInfo>.fromOpaque(encodeInfoToken.rawPointer).release()
            encodeInfo.completion?()
            releaseEncoderSlot()
            throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        return .accepted
    }

    func scheduleRecoveryKeyframe(reason: String) {
        guard !forceNextKeyframe else { return }
        forceNextKeyframe = true
        MirageLogger.encoder("Scheduling recovery keyframe (\(reason))")
    }
}

#endif
