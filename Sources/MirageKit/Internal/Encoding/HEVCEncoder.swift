import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

#if os(macOS)

/// Hardware-accelerated HEVC encoder using VideoToolbox
actor HEVCEncoder {
    private var compressionSession: VTCompressionSession?
    private let configuration: MirageEncoderConfiguration

    private var isEncoding = false
    private var frameNumber: UInt64 = 0
    private var encodedFrameHandler: ((Data, Bool, CMTime) -> Void)?
    private var forceNextKeyframe = false
    private var isUpdatingDimensions = false

    /// Current session dimensions (stored for reset)
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    /// Session version counter - incremented on each dimension change
    /// Used to discard frames from old sessions during transitions
    /// nonisolated(unsafe) because it's accessed from VT callback (different thread)
    /// and needs to be compared atomically
    nonisolated(unsafe) private var sessionVersion: UInt64 = 0

    init(configuration: MirageEncoderConfiguration) {
        self.configuration = configuration
    }

    /// Create the compression session
    func createSession(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_ARGB2101010LEPacked,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        try configureSession(session)
        compressionSession = session

        // Store dimensions for reset
        currentWidth = width
        currentHeight = height
    }

    private struct QualitySettings {
        let quality: Float
        let minQP: Int?
        let maxQP: Int?
    }

    private func qualitySettings(for quality: Float) -> QualitySettings {
        let clamped = max(0.02, min(1.0, quality))
        let useQP = clamped < 0.98
        guard useQP else {
            return QualitySettings(quality: clamped, minQP: nil, maxQP: nil)
        }
        let rawMin = 10.0 + (1.0 - Double(clamped)) * 36.0
        let clampedMin = max(10, min(46, Int(rawMin.rounded())))
        let maxQP = min(51, clampedMin + 12)
        return QualitySettings(quality: clamped, minQP: clampedMin, maxQP: maxQP)
    }

    private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            MirageLogger.error(.encoder, "VTSessionSetProperty \(key) failed: \(status)")
            return
        }
    }

    private func applyQualitySettings(_ session: VTCompressionSession, quality: Float, log: Bool) {
        let settings = qualitySettings(for: quality)
        setProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: settings.quality))

        if let minQP = settings.minQP {
            setProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: NSNumber(value: minQP))
        }
        if let maxQP = settings.maxQP {
            setProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: maxQP))
        }

        guard log else { return }
        let qualityText = settings.quality.formatted(.number.precision(.fractionLength(2)))
        if let minQP = settings.minQP, let maxQP = settings.maxQP {
            MirageLogger.encoder("Encoder quality: \(qualityText), QP \(minQP)-\(maxQP)")
        } else {
            MirageLogger.encoder("Encoder quality: \(qualityText)")
        }
    }

    private func configureSession(_ session: VTCompressionSession) throws {
        // Real-time encoding
        setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Disable B-frames for lowest latency
        setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Eliminate encoder buffering - critical for low latency streaming
        // Without this, the encoder may queue 1-2 frames before outputting
        setProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Frame rate
        setProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: configuration.targetFrameRate as CFNumber
        )

        // Bitrate
        setProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: configuration.maxBitrate as CFNumber
        )
        applyDataRateLimits(session, bitrate: configuration.maxBitrate)

        // Keyframe interval
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: configuration.keyFrameInterval as CFNumber
        )

        // Profile: Main10 for P3 color
        setProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel
        )

        // Prioritize encoding speed over quality for lower latency
        setProperty(
            session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue
        )
        MirageLogger.encoder("Prioritizing encoding speed over quality")

        // Apply quality setting - lower values reduce size for all frames
        applyQualitySettings(session, quality: configuration.keyframeQuality, log: true)

        // Note: kVTCompressionPropertyKey_ConstantBitRate is not supported by all HEVC encoders
        // The encoder will use its default rate control mode (typically VBR), which is fine
        // since we already have MaxFrameDelayCount=0 and RealTime=true for low latency

        // Color space configuration
        switch configuration.colorSpace {
        case .displayP3:
            // P3 uses P3-D65 primaries with sRGB transfer function and 709 YCbCr matrix
            setProperty(
                session,
                key: kVTCompressionPropertyKey_ColorPrimaries,
                value: kCMFormatDescriptionColorPrimaries_P3_D65
            )
            setProperty(
                session,
                key: kVTCompressionPropertyKey_TransferFunction,
                value: kCMFormatDescriptionTransferFunction_sRGB
            )
            setProperty(
                session,
                key: kVTCompressionPropertyKey_YCbCrMatrix,
                value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            )

        // TODO: HDR support - requires proper virtual display EDR configuration
        // case .hdr:
        //     // HDR uses Rec. 2020 primaries with PQ (SMPTE ST 2084) transfer function
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_ColorPrimaries,
        //         value: kCVImageBufferColorPrimaries_ITU_R_2020
        //     )
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_TransferFunction,
        //         value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        //     )
        //     VTSessionSetProperty(
        //         session,
        //         key: kVTCompressionPropertyKey_YCbCrMatrix,
        //         value: kCVImageBufferYCbCrMatrix_ITU_R_2020
        //     )
        //     MirageLogger.encoder("HDR encoding enabled: Rec. 2020 + PQ transfer function")

        case .sRGB:
            // sRGB uses standard Rec. 709 primaries
            break
        }

        // Prepare for encoding
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Pre-heat the encoder with dummy frames to eliminate warm-up latency
    /// VideoToolbox hardware encoders need ~5-10 frames to reach steady-state performance
    /// Without pre-heating, first real frames take 70-80ms instead of 3-4ms
    func preheat() async throws {
        guard let session = compressionSession else {
            MirageLogger.error(.encoder, "Cannot preheat: no compression session")
            return
        }

        let preheatStartTime = CFAbsoluteTimeGetCurrent()
        let preheatFrameCount = 10  // Enough frames to warm up rate control and hardware

        // Create a dummy pixel buffer at session dimensions
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,  // Standard HD - actual content dimensions don't matter for warm-up
            kCVPixelFormatType_ARGB2101010LEPacked,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &pixelBuffer
        )

        guard status == noErr, let buffer = pixelBuffer else {
            MirageLogger.error(.encoder, "Failed to create preheat buffer: \(status)")
            return
        }

        // Fill with gray (neutral content for rate control)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            // Fill with mid-gray pattern (0x80808080)
            memset(baseAddress, 0x80, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        MirageLogger.encoder("Pre-heating encoder with \(preheatFrameCount) dummy frames...")

        // Encode dummy frames and discard output
        for i in 0..<preheatFrameCount {
            let pts = CMTime(value: CMTimeValue(i), timescale: 60)
            let duration = CMTime(value: 1, timescale: 60)

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
        forceNextKeyframe = true  // First real frame should be keyframe

        let preheatDuration = (CFAbsoluteTimeGetCurrent() - preheatStartTime) * 1000
        MirageLogger.timing("Encoder pre-heat complete: \(String(format: "%.1f", preheatDuration))ms")
    }

    /// Start encoding with a frame handler
    func startEncoding(onEncodedFrame: @escaping (Data, Bool, CMTime) -> Void) {
        encodedFrameHandler = onEncodedFrame
        isEncoding = true
    }

    /// Stop encoding
    func stopEncoding() {
        isEncoding = false
        encodedFrameHandler = nil

        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
    }

    /// Encode a frame
    func encodeFrame(_ wrapper: SampleBufferWrapper, forceKeyframe: Bool = false) async throws {
        let encodeStartTime = CFAbsoluteTimeGetCurrent()  // Timing: encode start

        // Drop frames during dimension update to prevent deadlock
        guard !isUpdatingDimensions else { return }
        guard isEncoding, let session = compressionSession else { return }

        let sampleBuffer = wrapper.buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw MirageError.encodingError(NSError(domain: "MirageKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "No pixel buffer"]))
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Force keyframe on first frame or when requested
        let isFirstFrame = frameNumber == 0
        var properties: [CFString: Any] = [:]
        let isKeyframe = forceKeyframe || forceNextKeyframe || isFirstFrame
        if isKeyframe {
            MirageLogger.encoder("Forcing keyframe (first=\(isFirstFrame), forceNext=\(forceNextKeyframe), param=\(forceKeyframe))")
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
            guard status == noErr, let sampleBuffer else {
                Unmanaged<EncodeInfo>.fromOpaque(opaqueInfo).release()
                return
            }

            let info = Unmanaged<EncodeInfo>.fromOpaque(opaqueInfo).takeRetainedValue()

            // CRITICAL: Discard frames from old sessions during dimension transitions
            // This prevents sending P-frames encoded at old dimensions after a resize
            guard info.isSessionCurrent else {
                MirageLogger.encoder("Discarding frame \(info.frameNumber) from old session (version \(info.sessionVersion) != \(info.getCurrentVersion()))")
                return
            }

            // Timing: calculate encoding duration
            let encodeEndTime = CFAbsoluteTimeGetCurrent()
            let encodingDuration = (encodeEndTime - info.encodeStartTime) * 1000  // ms

            // Check if keyframe
            let isKeyframe = Self.isKeyframe(sampleBuffer)

            // Extract encoded data
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let pointer = dataPointer else { return }

            var data = Data(bytes: pointer, count: length)

            // For keyframes, prepend VPS/SPS/PPS with Annex B start codes
            if isKeyframe {
                // Extract parameter sets for keyframes
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    if let parameterSets = Self.extractParameterSets(from: formatDesc) {
                        data = parameterSets + data
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
                MirageLogger.debug(.timing, "Encoder frame \(info.frameNumber): \(String(format: "%.2f", encodingDuration))ms, \(String(format: "%.1f", bytesKB))KB\(isKeyframe ? " (keyframe)" : "")")
            }

            info.handler?(data, isKeyframe, pts)
        }

        if status != noErr {
            Unmanaged<EncodeInfo>.fromOpaque(opaqueInfo).release()
            throw MirageError.encodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
    }

    /// Update bitrate dynamically
    func updateBitrate(_ newBitrate: Int) {
        guard let session = compressionSession else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFNumber)
        applyDataRateLimits(session, bitrate: newBitrate)
    }

    /// Update quality dynamically (0.0 to 1.0)
    /// Lower quality reduces frame size during throughput pressure.
    func updateQuality(_ quality: Float) {
        guard let session = compressionSession else { return }
        applyQualitySettings(session, quality: quality, log: false)
    }

    private func applyDataRateLimits(_ session: VTCompressionSession, bitrate: Int) {
        let bytesPerSecond = max(1, bitrate / 8)
        let windowSeconds: Double = configuration.targetFrameRate >= 120 ? 0.25 : 0.5
        let bytesPerWindow = max(1, Int((Double(bytesPerSecond) * windowSeconds).rounded()))
        let limits = [
            NSNumber(value: bytesPerWindow),
            NSNumber(value: windowSeconds)
        ] as CFArray
        setProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// Update encoder dimensions (requires session recreation)
    func updateDimensions(width: Int, height: Int) async throws {
        MirageLogger.encoder("Updating dimensions to \(width)x\(height)")

        // Gate new frames from entering during update to prevent deadlock
        isUpdatingDimensions = true
        defer { isUpdatingDimensions = false }

        // Increment session version BEFORE completing old frames
        // This ensures any in-flight callbacks from old session will be discarded
        sessionVersion += 1
        MirageLogger.encoder("Session version incremented to \(sessionVersion)")

        // Complete and invalidate the old session
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        // Reset frame number to force keyframe on first frame of new session
        frameNumber = 0
        forceNextKeyframe = true

        // Create a new session with the new dimensions
        try createSession(width: width, height: height)
        MirageLogger.encoder("Session recreated with new dimensions")
    }

    /// Force a keyframe on next encode
    func forceKeyframe() {
        MirageLogger.encoder("Keyframe requested")
        forceNextKeyframe = true
    }

    func resetFrameNumber() {
        frameNumber = 0
    }

    /// Flush all pending frames from the encoder pipeline and force next keyframe.
    /// This ensures the next frame captured will be encoded as a keyframe immediately,
    /// without waiting for any in-flight frames to complete first.
    func flush() {
        guard let session = compressionSession else { return }

        // Complete all pending frames - this blocks until the encoder pipeline is clear
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        // Reset frame counter and force keyframe on next encode
        frameNumber = 0
        forceNextKeyframe = true

        MirageLogger.encoder("Encoder flushed - next frame will be keyframe")
    }

    /// Reset the encoder session to recover from stuck state
    /// This invalidates the current session and creates a new one
    /// Forces a keyframe on the next encode
    func reset() async throws {
        guard let session = compressionSession else { return }
        guard currentWidth > 0 && currentHeight > 0 else { return }

        MirageLogger.encoder("Resetting encoder session (\(currentWidth)x\(currentHeight))")

        // Invalidate the stuck session
        VTCompressionSessionInvalidate(session)
        compressionSession = nil

        // Reset frame number and force keyframe
        frameNumber = 0
        forceNextKeyframe = true

        // Create a fresh session with stored dimensions
        try createSession(width: currentWidth, height: currentHeight)

        MirageLogger.encoder("Encoder session reset complete")
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first else {
            return false
        }

        // If DependsOnOthers is false or not present, it's a keyframe
        if let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }

        return true
    }

    /// Extract VPS, SPS, PPS from format description and format with Annex B start codes
    private static func extractParameterSets(from formatDescription: CMFormatDescription) -> Data? {
        var result = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Get the number of parameter sets by querying index 0
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        // Log the result for debugging
        MirageLogger.encoder("Parameter set query: status=\(status), count=\(parameterSetCount), nalHeaderLen=\(nalUnitHeaderLength)")

        guard status == noErr else {
            MirageLogger.error(.encoder, "Failed to get parameter set count: \(status)")
            return nil
        }

        guard parameterSetCount >= 3 else {
            MirageLogger.error(.encoder, "Not enough parameter sets: \(parameterSetCount)")
            return nil
        }

        // Extract each parameter set (VPS at 0, SPS at 1, PPS at 2)
        for i in 0..<parameterSetCount {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize: Int = 0

            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: i,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            guard status == noErr, let pointer = parameterSetPointer else {
                MirageLogger.error(.encoder, "Failed to get parameter set \(i): \(status)")
                continue
            }

            // Append start code + parameter set
            result.append(contentsOf: startCode)
            result.append(pointer, count: parameterSetSize)
        }

        if result.isEmpty {
            return nil
        }

        MirageLogger.encoder("Extracted \(parameterSetCount) parameter sets")
        return result
    }
}

/// Info passed through the encode callback
private final class EncodeInfo: @unchecked Sendable {
    let frameNumber: UInt64
    let handler: ((Data, Bool, CMTime) -> Void)?
    let encodeStartTime: CFAbsoluteTime
    let sessionVersion: UInt64
    /// Closure to check current session version (captures encoder reference)
    let getCurrentVersion: () -> UInt64

    init(
        frameNumber: UInt64,
        handler: ((Data, Bool, CMTime) -> Void)?,
        encodeStartTime: CFAbsoluteTime = 0,
        sessionVersion: UInt64 = 0,
        getCurrentVersion: @escaping () -> UInt64
    ) {
        self.frameNumber = frameNumber
        self.handler = handler
        self.encodeStartTime = encodeStartTime
        self.sessionVersion = sessionVersion
        self.getCurrentVersion = getCurrentVersion
    }

    /// Check if this frame's session is still current
    /// Returns false if a dimension change occurred since this frame was queued
    var isSessionCurrent: Bool {
        return sessionVersion == getCurrentVersion()
    }
}

#endif
