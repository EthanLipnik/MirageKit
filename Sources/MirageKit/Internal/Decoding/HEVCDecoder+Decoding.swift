//
//  HEVCDecoder+Decoding.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

private struct SendableOpaquePointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer
}

extension HEVCDecoder {
    func startDecoding(onDecodedFrame: @escaping @Sendable (CVPixelBuffer, CMTime, CGRect) -> Void) {
        decodedFrameHandler = onDecodedFrame
        isDecoding = true
    }
    func stopDecoding() {
        isDecoding = false
        decodedFrameHandler = nil

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil

        // Clear cached parameter sets
        cachedVPS = nil
        cachedSPS = nil
        cachedPPS = nil
        cachedFormatDescription = nil

        invalidateMemoryPool()
    }
    func resetForNewSession() {
        // Invalidate current session - will be recreated on next keyframe
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        // Clear cached parameter sets so next keyframe is used fresh
        cachedVPS = nil
        cachedSPS = nil
        cachedPPS = nil
        cachedFormatDescription = nil

        // Clear dimension change state
        let wasBlocking = awaitingDimensionChange
        awaitingDimensionChange = false
        expectedDimensions = nil

        // Reset error tracking
        errorTracker?.recordSuccess()

        // Unblock input if we were blocking
        if wasBlocking {
            onInputBlockingChanged?(false)
        }

        flushMemoryPool()

        MirageLogger.decoder("Decoder reset for new session - awaiting fresh keyframe")
    }
    func decodeFrame(_ data: Data, presentationTime: CMTime, isKeyframe: Bool, contentRect: CGRect) async throws {
        guard isDecoding else { return }

        // CRITICAL: When awaiting dimension change, discard ALL P-frames.
        // P-frames at new dimensions will fail because decoder is configured for old dimensions.
        // Only keyframes contain VPS/SPS/PPS needed to reconfigure the decoder.
        if awaitingDimensionChange && !isKeyframe {
            // Check for timeout - if we've been waiting too long, request a new keyframe
            // This handles the case where the keyframe was lost over UDP
            let waitTime = CFAbsoluteTimeGetCurrent() - dimensionChangeStartTime
            if waitTime > dimensionChangeTimeout {
                MirageLogger.decoder("Dimension change timeout (\(String(format: "%.1f", waitTime))s) - requesting keyframe")
                dimensionChangeStartTime = CFAbsoluteTimeGetCurrent()  // Reset for next timeout cycle
                errorTracker?.requestKeyframeForDimensionChange()
            }
            // Silently discard P-frame - no error logging, no decode attempt
            return
        }

        var frameData = data

        // If keyframe, extract format description and strip parameter sets
        if isKeyframe {
            MirageLogger.decoder("Received keyframe (\(data.count) bytes)")
            // Diagnostic: log first 16 bytes to verify format
            let keyframeHeader = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            MirageLogger.decoder("Keyframe header: \(keyframeHeader)")
            let result = try extractFormatDescriptionAndStripParameterSets(from: data)
            frameData = result
            // Diagnostic: log first 16 bytes after stripping param sets + SEI
            let strippedHeader = frameData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            MirageLogger.decoder("IDR slice header (after strip): \(strippedHeader)")
        }

        guard let formatDesc = formatDescription else {
            // No format description yet - silently drop all frames until we receive
            // a keyframe with valid VPS/SPS/PPS parameter sets
            if isKeyframe {
                MirageLogger.error(.decoder, "Keyframe received but still no format description - parameter extraction failed")
            }
            return
        }

        // Ensure session exists
        if decompressionSession == nil {
            try createSession(formatDescription: formatDesc)
        }

        guard let session = decompressionSession else {
            throw MirageError.decodingError(NSError(domain: "MirageKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "No decompression session"]))
        }

        // Create block buffer with owned memory (VideoToolbox decodes asynchronously)
        // Using the memory pool allocator ensures CMBlockBuffer owns the memory and
        // reduces allocation churn across frames.
        let allocator = memoryPoolAllocator()
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frameData.count,
            blockAllocator: allocator,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else {
            throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        // Copy frame data into the block buffer's owned memory
        try frameData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw MirageError.decodingError(NSError(domain: "MirageKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "No frame data"]))
            }
            status = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: frameData.count
            )
            if status != noErr {
                throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            }
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(sampleStatus)))
        }

        // Decode
        var flags: VTDecodeInfoFlags = []

        let decodeInfo = DecodeInfo(
            handler: decodedFrameHandler,
            contentRect: contentRect,
            errorTracker: errorTracker,
            decodeStartTime: CFAbsoluteTimeGetCurrent(),
            performanceTracker: performanceTracker,
            releaseBuffer: nil,
            data: frameData
        )
        let opaqueInfo = SendableOpaquePointer(value: Unmanaged.passRetained(decodeInfo).toOpaque())

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flags
        ) { status, infoFlags, imageBuffer, presentationTime, duration in
            if status != noErr {
                // Common error codes:
                // -12909 (kVTVideoDecoderBadDataErr): Corrupted/incompatible data
                // -12911 (kVTVideoDecoderMalfunctionErr): Decoder malfunction
                // -12903 (kVTInvalidSessionErr): Session invalid
                let errorName: String
                switch status {
                case -12909: errorName = "BadData"
                case -12911: errorName = "Malfunction"
                case -12903: errorName = "InvalidSession"
                case -12910: errorName = "ReferenceMissing"
                default: errorName = "Unknown"
                }
                MirageLogger.error(.decoder, "Decode callback error: \(status) (\(errorName))")
                // Track consecutive errors to detect when we need a fresh keyframe
                let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo.value).takeRetainedValue()
                info.errorTracker?.recordError()
                return
            }
            guard let pixelBuffer = imageBuffer else {
                MirageLogger.error(.decoder, "Decode callback: no image buffer")
                let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo.value).takeRetainedValue()
                info.errorTracker?.recordError()
                return
            }

            MirageSignpost.emitEvent("DecodeOutput")

            let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo.value).takeRetainedValue()
            // Successful decode - reset error counter
            info.errorTracker?.recordSuccess()
            let decodeDurationMs = (CFAbsoluteTimeGetCurrent() - info.decodeStartTime) * 1000
            info.performanceTracker?.record(durationMs: decodeDurationMs)
            if info.handler != nil {
                info.handler?(pixelBuffer, presentationTime, info.contentRect)
            } else {
                MirageLogger.error(.decoder, "Warning: no frame handler set")
            }
        }

        if decodeStatus != noErr {
            Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo.value).release()
            throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(decodeStatus)))
        }
    }
    func flush() async {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
}
