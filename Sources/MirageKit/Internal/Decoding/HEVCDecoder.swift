import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics

/// Hardware-accelerated HEVC decoder using VideoToolbox
actor HEVCDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var outputPixelFormat: OSType = kCVPixelFormatType_ARGB2101010LEPacked

    /// Cached parameter sets for resilience against corrupted keyframes
    /// When a keyframe fails to parse, we can continue with cached format description
    private var cachedVPS: Data?
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    private var cachedFormatDescription: CMFormatDescription?

    private let memoryPoolAgeOutSeconds: TimeInterval = 1.0
    private var memoryPool: CMMemoryPool?

    private var isDecoding = false
    private var decodedFrameHandler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?

    /// Thread-safe error tracker for decode callbacks
    private var errorTracker: DecodeErrorTracker?
    /// Reduced from 15 to 5 for faster recovery from decode errors
    private let maxConsecutiveErrors = 5
    /// Thread-safe decode performance tracker (updated from decode callback)
    private let performanceTracker = DecodePerformanceTracker()

    /// Handler called when video dimensions change - used to reset reassembler
    private var onDimensionChange: (@Sendable () -> Void)?

    /// Handler called when input blocking state changes (true = block input, false = allow input)
    /// Input should be blocked when decoder is awaiting keyframe or has decode errors
    private var onInputBlockingChanged: (@Sendable (Bool) -> Void)?

    /// When true, discard all P-frames and only process keyframes.
    /// Set when client initiates a resize request - P-frames at new dimensions will fail
    /// until we receive a keyframe with the new VPS/SPS/PPS parameter sets.
    private var awaitingDimensionChange = false

    /// Time when dimension change started (for timeout detection)
    private var dimensionChangeStartTime: CFAbsoluteTime = 0

    /// Timeout for awaiting dimension change (seconds) before re-requesting keyframe
    private let dimensionChangeTimeout: CFAbsoluteTime = 2.0

    /// Expected dimensions after resize (optional, for validation)
    private var expectedDimensions: (width: Int, height: Int)?

    private func configureMemoryPoolIfNeeded() {
        guard memoryPool == nil else { return }
        let options: [CFString: Any] = [
            kCMMemoryPoolOption_AgeOutPeriod: NSNumber(value: memoryPoolAgeOutSeconds)
        ]
        memoryPool = CMMemoryPoolCreate(options: options as CFDictionary)
    }

    private func memoryPoolAllocator() -> CFAllocator {
        configureMemoryPoolIfNeeded()
        guard let memoryPool else { return kCFAllocatorDefault }
        return CMMemoryPoolGetAllocator(memoryPool)
    }

    private func flushMemoryPool() {
        guard let memoryPool else { return }
        CMMemoryPoolFlush(memoryPool)
    }

    private func invalidateMemoryPool() {
        guard let memoryPool else { return }
        CMMemoryPoolInvalidate(memoryPool)
        self.memoryPool = nil
    }

    /// Set handler called when decode errors exceed threshold, indicating need for keyframe
    func setErrorThresholdHandler(_ handler: @escaping @Sendable () -> Void) {
        // Wrap the handler to also block input when errors exceed threshold
        let wrappedHandler: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                await self.onInputBlockingChanged?(true)
            }
            handler()
        }
        let inputUnblockHandler: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                await self.onInputBlockingChanged?(false)
            }
        }
        errorTracker = DecodeErrorTracker(
            maxErrors: maxConsecutiveErrors,
            onThresholdReached: wrappedHandler,
            onRecovery: inputUnblockHandler
        )
    }

    /// Set handler called when video dimensions change
    /// Used to reset the reassembler and discard pending old-dimension fragments
    func setDimensionChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        onDimensionChange = handler
    }

    /// Set handler called when input blocking state changes
    /// Input should be blocked when decoder is in a bad state (awaiting keyframe, decode errors)
    func setInputBlockingHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        onInputBlockingChanged = handler
    }

    /// Get the current average decode time (ms) from recent samples.
    func getAverageDecodeTimeMs() -> Double {
        performanceTracker.averageMs()
    }

    /// Get the total decode error count (lifetime).
    func getTotalDecodeErrors() -> UInt64 {
        errorTracker?.totalErrorsSnapshot() ?? 0
    }

    /// Called when client initiates a resize request.
    /// Puts decoder in "awaiting dimension change" mode where P-frames are discarded
    /// until a keyframe with new VPS/SPS/PPS arrives.
    func prepareForDimensionChange(expectedWidth: Int? = nil, expectedHeight: Int? = nil) {
        awaitingDimensionChange = true
        dimensionChangeStartTime = CFAbsoluteTimeGetCurrent()
        if let w = expectedWidth, let h = expectedHeight {
            expectedDimensions = (w, h)
        } else {
            expectedDimensions = nil
        }
        MirageLogger.decoder("Dimension change expected - discarding P-frames until keyframe")
        // Block input while awaiting keyframe - user can't see what they're clicking
        onInputBlockingChanged?(true)
    }

    /// Clear any stuck state that prevents frame processing.
    /// Called when recovering from app backgrounding to ensure decoder accepts new frames.
    func clearPendingState() {
        let wasBlocking = awaitingDimensionChange
        if awaitingDimensionChange {
            MirageLogger.decoder("Clearing stuck awaitingDimensionChange state for recovery")
            awaitingDimensionChange = false
            expectedDimensions = nil
        }
        // Reset error tracking to give fresh keyframe a clean slate
        errorTracker?.recordSuccess()
        // Unblock input if we were blocking
        if wasBlocking {
            onInputBlockingChanged?(false)
        }
    }

    /// Start decoding with a frame handler
    func startDecoding(onDecodedFrame: @escaping @Sendable (CVPixelBuffer, CMTime, CGRect) -> Void) {
        decodedFrameHandler = onDecodedFrame
        isDecoding = true
    }

    /// Stop decoding
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

    /// Reset the decoder state for a new stream session (e.g., after resize or reconnection).
    /// Clears cached VPS/SPS/PPS so the next keyframe will be used to configure the decoder.
    /// Unlike stopDecoding(), this keeps the decoder running and ready to receive new frames.
    func resetForNewSession() {
        // Invalidate current session - will be recreated on next keyframe
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        outputPixelFormat = kCVPixelFormatType_ARGB2101010LEPacked

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

    /// Decode an encoded frame
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
            performanceTracker: performanceTracker
        )
        let opaqueInfo = Unmanaged.passRetained(decodeInfo).toOpaque()

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
                let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo).takeRetainedValue()
                info.errorTracker?.recordError()
                return
            }
            guard let pixelBuffer = imageBuffer else {
                MirageLogger.error(.decoder, "Decode callback: no image buffer")
                let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo).takeRetainedValue()
                info.errorTracker?.recordError()
                return
            }

            let info = Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo).takeRetainedValue()
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
            Unmanaged<DecodeInfo>.fromOpaque(opaqueInfo).release()
            throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(decodeStatus)))
        }
    }

    /// Extract format description from parameter sets and return data with parameter sets stripped
    private func extractFormatDescriptionAndStripParameterSets(from data: Data) throws -> Data {
        if let framed = splitFramedKeyframeData(from: data) {
            return try extractFormatDescriptionAndStripParameterSets(
                parameterSetsData: framed.parameterSets,
                frameData: framed.frameData
            )
        }

        // Parse HEVC NAL units to extract VPS, SPS, PPS (in Annex B format)
        // NAL unit types: VPS=32, SPS=33, PPS=34
        // After parameter sets, the data transitions to AVCC format (length-prefixed, no start codes)

        // First, find all start code positions in the first 200 bytes
        // Parameter sets are small (~85 bytes total with start codes)
        var startCodePositions: [(position: Int, length: Int)] = []
        var i = 0
        let searchLimit = min(data.count, 200)

        while i < searchLimit - 3 {
            if data[i] == 0x00 && data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    startCodePositions.append((i, 3))
                    i += 3
                    continue
                } else if i + 3 < searchLimit && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                    startCodePositions.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard startCodePositions.count >= 3 else {
            MirageLogger.error(.decoder, "Not enough start codes found: \(startCodePositions.count)")
            return data
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?
        var parameterSetsEnd: Int = 0

        // Extract each NAL unit between consecutive start codes
        for (idx, startCode) in startCodePositions.enumerated() {
            let nalStart = startCode.position + startCode.length
            let nalEnd: Int

            if idx + 1 < startCodePositions.count {
                // NAL ends where next start code begins
                nalEnd = startCodePositions[idx + 1].position
            } else {
                // Last start code - this is PPS, need to find where AVCC starts
                // Scan forward from NAL start looking for AVCC length prefix
                nalEnd = findAVCCBoundary(in: data, after: nalStart)
            }

            guard nalEnd > nalStart && nalStart < data.count else { continue }
            let actualEnd = min(nalEnd, data.count)
            let nalData = data.subdata(in: nalStart..<actualEnd)
            guard !nalData.isEmpty else { continue }

            // HEVC NAL unit header is 2 bytes
            // NAL type is in bits 1-6 of first byte (shift right by 1, mask with 0x3F)
            let nalType = (nalData[0] >> 1) & 0x3F

            switch nalType {
            case 32: // VPS
                vps = nalData
                parameterSetsEnd = nalEnd
            case 33: // SPS
                sps = nalData
                parameterSetsEnd = nalEnd
            case 34: // PPS
                pps = nalData
                parameterSetsEnd = nalEnd
            default:
                break
            }
        }

        // Need all three parameter sets
        guard let vpsData = vps, let spsData = sps, let ppsData = pps else {
            MirageLogger.error(.decoder, "Missing parameter sets - VPS: \(vps != nil), SPS: \(sps != nil), PPS: \(pps != nil)")

            // Try to use cached format description if available
            if let cached = cachedFormatDescription {
                MirageLogger.decoder("Using cached format description due to corrupted keyframe")
                self.formatDescription = cached
            }

            return data // Return original data, will try again on next keyframe
        }

        // Cache the parameter sets for resilience
        self.cachedVPS = vpsData
        self.cachedSPS = spsData
        self.cachedPPS = ppsData

        try updateFormatDescription(vpsData: vpsData, spsData: spsData, ppsData: ppsData)

        // Return data with parameter sets stripped (the remaining AVCC data)
        if parameterSetsEnd > 0 && parameterSetsEnd < data.count {
            var strippedData = Data(data.suffix(from: parameterSetsEnd))

            // Strip any leading SEI NAL units that may confuse VideoToolbox
            // SEI (Supplemental Enhancement Information) contains metadata like HDR info
            // VideoToolbox may not properly decode IDR when SEI comes first
            strippedData = stripSEINALUnits(from: strippedData)

            return strippedData
        }

        return data
    }

    private func splitFramedKeyframeData(from data: Data) -> (parameterSets: Data, frameData: Data)? {
        guard data.count > 8 else { return nil }

        let length = UInt32(data[0]) << 24 |
                     UInt32(data[1]) << 16 |
                     UInt32(data[2]) << 8 |
                     UInt32(data[3])
        guard length > 0 else { return nil }

        let start = 4
        let end = start + Int(length)
        guard end > start, end <= data.count else { return nil }

        let parameterSets = data.subdata(in: start..<end)
        let hasStartCode = parameterSets.starts(with: [0x00, 0x00, 0x00, 0x01]) ||
                           parameterSets.starts(with: [0x00, 0x00, 0x01])
        guard hasStartCode else { return nil }

        let frameData = data.subdata(in: end..<data.count)
        guard !frameData.isEmpty else { return nil }

        return (parameterSets, frameData)
    }

    private func extractFormatDescriptionAndStripParameterSets(
        parameterSetsData: Data,
        frameData: Data
    ) throws -> Data {
        let sets = extractParameterSets(from: parameterSetsData)
        guard let vpsData = sets.vps, let spsData = sets.sps, let ppsData = sets.pps else {
            MirageLogger.error(.decoder, "Missing parameter sets - VPS: \(sets.vps != nil), SPS: \(sets.sps != nil), PPS: \(sets.pps != nil)")

            if let cached = cachedFormatDescription {
                MirageLogger.decoder("Using cached format description due to corrupted keyframe")
                self.formatDescription = cached
            }

            return stripSEINALUnits(from: frameData)
        }

        self.cachedVPS = vpsData
        self.cachedSPS = spsData
        self.cachedPPS = ppsData

        try updateFormatDescription(vpsData: vpsData, spsData: spsData, ppsData: ppsData)

        return stripSEINALUnits(from: frameData)
    }

    private func extractParameterSets(from data: Data) -> (vps: Data?, sps: Data?, pps: Data?) {
        var startCodePositions: [(position: Int, length: Int)] = []
        var i = 0
        let searchLimit = max(0, data.count - 3)

        while i < searchLimit {
            if data[i] == 0x00 && data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    startCodePositions.append((i, 3))
                    i += 3
                    continue
                } else if i + 3 < data.count && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                    startCodePositions.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard startCodePositions.count >= 3 else {
            MirageLogger.error(.decoder, "Not enough start codes found: \(startCodePositions.count)")
            return (nil, nil, nil)
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?

        for (idx, startCode) in startCodePositions.enumerated() {
            let nalStart = startCode.position + startCode.length
            let nalEnd = idx + 1 < startCodePositions.count ? startCodePositions[idx + 1].position : data.count

            guard nalEnd > nalStart && nalStart < data.count else { continue }
            let nalData = data.subdata(in: nalStart..<nalEnd)
            guard !nalData.isEmpty else { continue }

            let nalType = (nalData[0] >> 1) & 0x3F
            switch nalType {
            case 32:
                vps = nalData
            case 33:
                sps = nalData
            case 34:
                pps = nalData
            default:
                break
            }
        }

        return (vps, sps, pps)
    }

    private func updateFormatDescription(vpsData: Data, spsData: Data, ppsData: Data) throws {
        try vpsData.withUnsafeBytes { vpsPtr in
            try spsData.withUnsafeBytes { spsPtr in
                try ppsData.withUnsafeBytes { ppsPtr in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    let parameterSetSizes: [Int] = [vpsData.count, spsData.count, ppsData.count]

                    var formatDesc: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )

                    guard status == noErr, let desc = formatDesc else {
                        if let cached = self.cachedFormatDescription {
                            MirageLogger.decoder("Format description creation failed (status \(status)), using cached")
                            self.formatDescription = cached
                            return
                        }
                        throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                            userInfo: [NSLocalizedDescriptionKey: "Failed to create format description"]))
                    }

                    let oldDims = self.formatDescription.flatMap { CMVideoFormatDescriptionGetDimensions($0) }
                    let newDims = CMVideoFormatDescriptionGetDimensions(desc)

                    let dimensionsMismatch = oldDims.map { old in
                        old.width != newDims.width || old.height != newDims.height
                    } ?? false

                    let isFirstKeyframe = oldDims == nil
                    let shouldRecreateForErrors = !isFirstKeyframe && (self.errorTracker?.shouldRecreateSession() ?? false)
                    let shouldRecreateSession = dimensionsMismatch || shouldRecreateForErrors

                    if isFirstKeyframe {
                        MirageLogger.decoder("First keyframe - session will be created fresh (\(newDims.width)x\(newDims.height))")
                    }

                    if shouldRecreateSession {
                        if dimensionsMismatch, let old = oldDims {
                            MirageLogger.decoder("Dimensions changed from \(old.width)x\(old.height) to \(newDims.width)x\(newDims.height) - recreating session")
                        } else if shouldRecreateForErrors {
                            MirageLogger.decoder("Recreating session due to decode errors (dimensions unchanged: \(newDims.width)x\(newDims.height))")
                        }

                        if let session = self.decompressionSession {
                            VTDecompressionSessionInvalidate(session)
                            self.decompressionSession = nil
                        }

                        if dimensionsMismatch {
                            self.errorTracker?.requestKeyframeForDimensionChange()
                            self.onDimensionChange?()
                            self.errorTracker?.clearForDimensionChange()
                        } else if shouldRecreateForErrors {
                            self.errorTracker?.markSessionRecreated()
                        }
                    }

                    self.outputPixelFormat = preferredOutputPixelFormat(for: desc)
                    self.formatDescription = desc
                    self.cachedFormatDescription = desc
                    MirageLogger.decoder("Created format description successfully (\(newDims.width)x\(newDims.height))")

                    if self.awaitingDimensionChange {
                        self.awaitingDimensionChange = false
                        self.expectedDimensions = nil
                        MirageLogger.decoder("Dimension change complete - resuming normal P-frame processing")
                        self.onInputBlockingChanged?(false)
                    }
                }
            }
        }
    }

    private func preferredOutputPixelFormat(for formatDescription: CMFormatDescription) -> OSType {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
              let bits = extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? Int else {
            return kCVPixelFormatType_ARGB2101010LEPacked
        }
        return bits > 8 ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA
    }

    /// Strip leading SEI NAL units from AVCC data
    /// SEI NAL types: 39 (PREFIX_SEI_NUT), 40 (SUFFIX_SEI_NUT)
    /// Note: SEI contains HDR metadata but VideoToolbox may not decode properly if SEI precedes IDR
    private func stripSEINALUnits(from data: Data) -> Data {
        var result = data

        while result.count > 5 {
            // Read AVCC length (4 bytes big-endian)
            let length = UInt32(result[0]) << 24 |
                         UInt32(result[1]) << 16 |
                         UInt32(result[2]) << 8 |
                         UInt32(result[3])

            // Sanity check: length must be reasonable
            guard length > 0 && length < result.count - 4 else { break }

            // Read NAL type from 5th byte (first byte after length prefix)
            // HEVC NAL header: forbidden_zero_bit(1) | nal_unit_type(6) | nuh_layer_id_high(1)
            let nalType = (result[4] >> 1) & 0x3F

            // SEI NAL types: 39 (PREFIX_SEI_NUT), 40 (SUFFIX_SEI_NUT)
            if nalType == 39 || nalType == 40 {
                // Skip this SEI NAL unit (4-byte length prefix + NAL data)
                let skipBytes = 4 + Int(length)
                if skipBytes < result.count {
                    result = Data(result.dropFirst(skipBytes))
                    MirageLogger.decoder("Stripped SEI NAL (type \(nalType), \(length) bytes)")
                    continue
                }
            }

            // Not a SEI, stop stripping
            break
        }

        return result
    }

    /// Find where AVCC data begins after the last Annex B NAL unit (PPS)
    /// AVCC uses 4-byte big-endian length prefixes instead of start codes
    private func findAVCCBoundary(in data: Data, after nalStart: Int) -> Int {
        // PPS NAL is typically 5-15 bytes. Scan forward looking for AVCC length prefix.
        // Skip the 2-byte NAL header first
        var pos = nalStart + 2
        let scanLimit = min(data.count - 4, nalStart + 50)

        while pos < scanLimit {
            // Read 4 bytes as potential AVCC length (big-endian)
            let b0 = UInt32(data[pos])
            let b1 = UInt32(data[pos + 1])
            let b2 = UInt32(data[pos + 2])
            let b3 = UInt32(data[pos + 3])
            let potentialLength = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            // Check if this could be a start code (we're still in Annex B)
            if b0 == 0x00 && b1 == 0x00 && (b2 == 0x01 || (b2 == 0x00 && b3 == 0x01)) {
                // Found another start code, boundary is here
                return pos
            }

            // Check if this looks like a valid AVCC length:
            // - Not 0 or 1 (too small for a NAL)
            // - Reasonable size for a video NAL (> 10 bytes, < remaining data)
            let remainingData = data.count - pos - 4
            if potentialLength > 10 && potentialLength < remainingData {
                // This looks like AVCC, boundary is here
                return pos
            }

            pos += 1
        }

        // Fallback: assume PPS is about 10 bytes
        return min(nalStart + 10, data.count)
    }

    /// Parse NAL units from Annex B data and return with end positions
    private func parseNALUnitsWithPositions(from data: Data) -> [(Data, Int)] {
        var nalUnits: [(Data, Int)] = []
        var currentIndex = 0

        while currentIndex < data.count {
            // Look for start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
            var startCodeLength = 0
            var foundStartCode = false

            if currentIndex + 3 <= data.count {
                if data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 {
                    if data[currentIndex + 2] == 0x01 {
                        startCodeLength = 3
                        foundStartCode = true
                    } else if currentIndex + 4 <= data.count &&
                              data[currentIndex + 2] == 0x00 && data[currentIndex + 3] == 0x01 {
                        startCodeLength = 4
                        foundStartCode = true
                    }
                }
            }

            if foundStartCode {
                currentIndex += startCodeLength

                // Find next start code or end of data
                var nextStart = currentIndex
                while nextStart < data.count {
                    if nextStart + 3 <= data.count &&
                       data[nextStart] == 0x00 && data[nextStart + 1] == 0x00 &&
                       (data[nextStart + 2] == 0x01 ||
                        (nextStart + 4 <= data.count && data[nextStart + 2] == 0x00 && data[nextStart + 3] == 0x01)) {
                        break
                    }
                    nextStart += 1
                }

                // Extract NAL unit
                if nextStart > currentIndex {
                    let nalUnit = data.subdata(in: currentIndex..<nextStart)
                    nalUnits.append((nalUnit, nextStart))
                }
                currentIndex = nextStart
            } else {
                // No more Annex B start codes found, remaining data is AVCC format
                break
            }
        }

        return nalUnits
    }

    /// Parse NAL units from Annex B or length-prefixed data
    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0

        while currentIndex < data.count {
            // Look for start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
            var startCodeLength = 0
            var foundStartCode = false

            if currentIndex + 3 <= data.count {
                if data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 {
                    if data[currentIndex + 2] == 0x01 {
                        startCodeLength = 3
                        foundStartCode = true
                    } else if currentIndex + 4 <= data.count &&
                              data[currentIndex + 2] == 0x00 && data[currentIndex + 3] == 0x01 {
                        startCodeLength = 4
                        foundStartCode = true
                    }
                }
            }

            if foundStartCode {
                currentIndex += startCodeLength

                // Find next start code or end of data
                var nextStart = currentIndex
                while nextStart < data.count {
                    if nextStart + 3 <= data.count &&
                       data[nextStart] == 0x00 && data[nextStart + 1] == 0x00 &&
                       (data[nextStart + 2] == 0x01 ||
                        (nextStart + 4 <= data.count && data[nextStart + 2] == 0x00 && data[nextStart + 3] == 0x01)) {
                        break
                    }
                    nextStart += 1
                }

                // Extract NAL unit
                if nextStart > currentIndex {
                    let nalUnit = data.subdata(in: currentIndex..<nextStart)
                    nalUnits.append(nalUnit)
                }
                currentIndex = nextStart
            } else {
                currentIndex += 1
            }
        }

        return nalUnits
    }

    private func createSession(formatDescription: CMFormatDescription) throws {
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
            ] as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw MirageError.decodingError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        // Configure for real-time decoding
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        decompressionSession = session
    }

    /// Flush pending frames
    func flush() async {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
}

/// Info passed through the decode callback
private final class DecodeInfo: @unchecked Sendable {
    let handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?
    let contentRect: CGRect
    let errorTracker: DecodeErrorTracker?
    let decodeStartTime: CFAbsoluteTime
    let performanceTracker: DecodePerformanceTracker?

    init(
        handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?,
        contentRect: CGRect,
        errorTracker: DecodeErrorTracker?,
        decodeStartTime: CFAbsoluteTime,
        performanceTracker: DecodePerformanceTracker?
    ) {
        self.handler = handler
        self.contentRect = contentRect
        self.errorTracker = errorTracker
        self.decodeStartTime = decodeStartTime
        self.performanceTracker = performanceTracker
    }
}

/// Thread-safe error tracker for decode callbacks
/// Used to detect when decoder enters a bad state and needs a keyframe
private final class DecodeErrorTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var consecutiveErrors: Int = 0
    private let maxConsecutiveErrors: Int
    private let onThresholdReached: @Sendable () -> Void
    private let onRecovery: (@Sendable () -> Void)?
    private var thresholdFired = false
    private var lastThresholdTime: CFAbsoluteTime = 0
    private var totalErrors: UInt64 = 0

    /// Minimum time between keyframe requests (seconds)
    /// 1.0s prevents keyframe request flooding during transient packet loss
    private let retryInterval: CFAbsoluteTime = 1.0

    /// Number of errors to accumulate before retrying after initial request
    /// 10 errors balances fast retry with avoiding excessive keyframe requests
    private let retryErrorThreshold: Int = 10

    /// Flag indicating session recreation has been attempted for current error episode.
    /// Set when session is recreated, cleared on successful decode.
    /// Prevents rapid recreation on consecutive keyframes.
    private var sessionRecreationAttempted = false

    /// Time of last session recreation attempt (for cooldown)
    private var lastSessionRecreationTime: CFAbsoluteTime = 0

    /// Minimum time between session recreations (seconds)
    private let sessionRecreationCooldown: CFAbsoluteTime = 2.0

    init(maxErrors: Int, onThresholdReached: @escaping @Sendable () -> Void, onRecovery: (@Sendable () -> Void)? = nil) {
        self.maxConsecutiveErrors = maxErrors
        self.onThresholdReached = onThresholdReached
        self.onRecovery = onRecovery
    }

    /// Record a decode error. Returns true if threshold was just exceeded.
    func recordError() {
        lock.lock()
        defer { lock.unlock() }

        consecutiveErrors += 1
        totalErrors += 1
        let now = CFAbsoluteTimeGetCurrent()

        // Initial threshold fire
        if consecutiveErrors >= maxConsecutiveErrors && !thresholdFired {
            thresholdFired = true
            lastThresholdTime = now
            // Call handler outside lock to avoid deadlocks
            lock.unlock()
            MirageLogger.decoder("Decode error threshold reached (\(consecutiveErrors) errors) - requesting keyframe")
            onThresholdReached()
            lock.lock()
            return
        }

        // Retry logic: if errors continue after initial request, retry periodically
        // This handles the case where the keyframe was lost over UDP
        if thresholdFired && consecutiveErrors >= retryErrorThreshold {
            let timeSinceLastRequest = now - lastThresholdTime
            if timeSinceLastRequest >= retryInterval {
                lastThresholdTime = now
                consecutiveErrors = 0  // Reset counter for next retry cycle
                lock.unlock()
                MirageLogger.decoder("Keyframe retry - errors persisted for \(String(format: "%.1f", timeSinceLastRequest))s")
                onThresholdReached()
                lock.lock()
            }
        }
    }

    /// Record a successful decode, resetting the error counter
    func recordSuccess() {
        lock.lock()

        let wasInErrorState = thresholdFired || consecutiveErrors > maxConsecutiveErrors
        if consecutiveErrors > 0 || sessionRecreationAttempted {
            MirageLogger.decoder("Decode recovered after \(consecutiveErrors) consecutive errors (sessionRecreated=\(sessionRecreationAttempted))")
        }
        consecutiveErrors = 0
        thresholdFired = false
        sessionRecreationAttempted = false

        lock.unlock()

        // Notify recovery if we were in an error state (input was blocked)
        if wasInErrorState {
            onRecovery?()
        }
    }

    /// Request keyframe immediately due to dimension change
    /// This is more urgent than error-based requests - dimensions changed so ALL old frames will fail
    func requestKeyframeForDimensionChange() {
        lock.lock()
        consecutiveErrors = 0  // Reset since dimension change makes error count meaningless
        thresholdFired = true  // Mark as already fired to prevent duplicate immediate requests
        lastThresholdTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        MirageLogger.decoder("Requesting keyframe due to dimension change")
        onThresholdReached()
    }

    /// Check if session recreation should be attempted on keyframe receipt.
    /// Returns true only if:
    /// 1. We've had decode errors (thresholdFired or consecutiveErrors > 0)
    /// 2. Session recreation hasn't been attempted yet OR cooldown has passed
    func shouldRecreateSession() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let hasErrors = thresholdFired || consecutiveErrors > 0
        if !hasErrors {
            return false
        }

        // If we haven't tried recreation yet, allow it
        if !sessionRecreationAttempted {
            return true
        }

        // If recreation was attempted, only allow again after cooldown
        let now = CFAbsoluteTimeGetCurrent()
        let timeSinceLastRecreation = now - lastSessionRecreationTime
        return timeSinceLastRecreation >= sessionRecreationCooldown
    }

    /// Mark that session has been recreated.
    /// Called after decoder recreates session on keyframe.
    func markSessionRecreated() {
        lock.lock()
        defer { lock.unlock() }
        sessionRecreationAttempted = true
        lastSessionRecreationTime = CFAbsoluteTimeGetCurrent()
        MirageLogger.decoder("Session recreation attempted - awaiting successful decode")
    }

    /// Clear error tracking state for dimension change.
    /// Called when dimensions change to give the decoder a clean slate.
    /// Unlike markSessionRecreated(), this doesn't impose a cooldown since
    /// dimension changes inherently require a fresh session anyway.
    func clearForDimensionChange() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveErrors = 0
        thresholdFired = false
        sessionRecreationAttempted = false
        lastSessionRecreationTime = 0
        MirageLogger.decoder("Error tracking cleared for dimension change")
    }

    func totalErrorsSnapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalErrors
    }
}

/// Thread-safe decode timing tracker for recent samples
private final class DecodePerformanceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private let maxSamples: Int = 30

    func record(durationMs: Double) {
        lock.lock()
        samples.append(durationMs)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        lock.unlock()
    }

    func averageMs() -> Double {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return 0 }
        let total = snapshot.reduce(0, +)
        return total / Double(snapshot.count)
    }
}

/// Reassembles video frames from network packets
/// Each reassembler is associated with a specific stream for multi-stream support
actor FrameReassembler {
    /// The stream ID this reassembler handles
    let streamID: StreamID

    private var pendingFrames: [UInt32: PendingFrame] = [:]
    private var lastCompletedFrame: UInt32 = 0
    private var lastDeliveredKeyframe: UInt32 = 0
    private var droppedFrameCount: UInt64 = 0
    private var awaitingKeyframe: Bool = false
    private var currentEpoch: UInt16 = 0

    /// Expected dimension token - frames with mismatched tokens are silently discarded.
    /// Updated when stream starts or client receives a resize notification.
    /// Initial value of 0 accepts all frames until explicitly set.
    private var expectedDimensionToken: UInt16 = 0

    /// Whether dimension token validation is enabled.
    /// Disabled by default to maintain backward compatibility with older hosts.
    private var dimensionTokenValidationEnabled: Bool = false

    /// Frame completion callback: (streamID, frameData, isKeyframe, timestamp, contentRect)
    private var onFrameComplete: (@Sendable (StreamID, Data, Bool, UInt64, CGRect) -> Void)?

    // MARK: - Diagnostic counters
    private var totalPacketsReceived: UInt64 = 0
    private var framesDelivered: UInt64 = 0
    private var packetsDiscardedOld: UInt64 = 0
    private var packetsDiscardedCRC: UInt64 = 0
    private var packetsDiscardedToken: UInt64 = 0
    private var packetsDiscardedAwaitingKeyframe: UInt64 = 0
    private var packetsDiscardedEpoch: UInt64 = 0
    private var lastStatsLog: UInt64 = 0

    struct PendingFrame {
        var fragments: [UInt16: Data]
        var totalFragments: UInt16
        var isKeyframe: Bool
        var timestamp: UInt64
        var receivedAt: Date
        var contentRect: CGRect
    }

    init(streamID: StreamID) {
        self.streamID = streamID
    }

    func setFrameHandler(_ handler: @escaping @Sendable (StreamID, Data, Bool, UInt64, CGRect) -> Void) {
        onFrameComplete = handler
    }

    /// Update the expected dimension token for this stream.
    /// Frames with mismatched tokens will be silently discarded.
    /// Called when stream starts or when client is notified of a resize.
    /// - Parameter token: The new expected dimension token from the host
    func updateExpectedDimensionToken(_ token: UInt16) {
        expectedDimensionToken = token
        dimensionTokenValidationEnabled = true
        MirageLogger.log(.frameAssembly, "Expected dimension token updated to \(token) for stream \(streamID)")
    }

    /// Process a received packet
    func processPacket(_ data: Data, header: FrameHeader) {
        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        totalPacketsReceived += 1

        // Log stats every 1000 packets
        if totalPacketsReceived - lastStatsLog >= 1000 {
            lastStatsLog = totalPacketsReceived
            MirageLogger.log(.frameAssembly, "STATS: packets=\(totalPacketsReceived), framesDelivered=\(framesDelivered), pending=\(pendingFrames.count), discarded(old=\(packetsDiscardedOld), crc=\(packetsDiscardedCRC), token=\(packetsDiscardedToken), epoch=\(packetsDiscardedEpoch), awaitKeyframe=\(packetsDiscardedAwaitingKeyframe))")
        }

        if header.epoch != currentEpoch {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "epoch mismatch")
            } else {
                packetsDiscardedEpoch += 1
                awaitingKeyframe = true
                return
            }
        }

        if header.flags.contains(.discontinuity) {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "discontinuity")
            } else {
                packetsDiscardedEpoch += 1
                awaitingKeyframe = true
                return
            }
        }

        // Validate dimension token to reject old-dimension frames after resize.
        // Keyframes always update the expected token since they establish new dimensions.
        // P-frames with mismatched tokens are silently discarded.
        if dimensionTokenValidationEnabled {
            if isKeyframePacket {
                // Keyframes update the expected token - they carry new VPS/SPS/PPS
                if header.dimensionToken != expectedDimensionToken {
                    MirageLogger.log(.frameAssembly, "Keyframe updated dimension token from \(expectedDimensionToken) to \(header.dimensionToken)")
                    expectedDimensionToken = header.dimensionToken
                }
            } else if header.dimensionToken != expectedDimensionToken {
                // P-frame with wrong token - silently discard (old dimensions)
                packetsDiscardedToken += 1
                return
            }
        }

        if awaitingKeyframe && !isKeyframePacket {
            packetsDiscardedAwaitingKeyframe += 1
            return
        }

        // Validate CRC32 checksum to detect corrupted packets
        let calculatedCRC = CRC32.calculate(data)
        if calculatedCRC != header.checksum {
            packetsDiscardedCRC += 1
            MirageLogger.log(.frameAssembly, "CRC mismatch for frame \(frameNumber) fragment \(header.fragmentIndex) - discarding (expected \(header.checksum), got \(calculatedCRC))")
            return
        }

        // Skip old P-frames, but NEVER skip keyframe packets.
        // Keyframes are large (400+ packets) and take longer to transmit than small P-frames.
        // P-frames sent after a keyframe may complete before the keyframe finishes.
        // If we skip "old" keyframe packets, recovery becomes impossible.
        let isOldFrame = frameNumber < lastCompletedFrame && lastCompletedFrame - frameNumber < 1000
        if isOldFrame && !isKeyframePacket {
            packetsDiscardedOld += 1
            return
        }

        // Get or create pending frame
        var frame = pendingFrames[frameNumber] ?? PendingFrame(
            fragments: [:],
            totalFragments: header.fragmentCount,
            isKeyframe: isKeyframePacket,
            timestamp: header.timestamp,
            receivedAt: Date(),
            contentRect: header.contentRect
        )

        // Update keyframe flag if this packet has it (in case fragments arrive out of order)
        if isKeyframePacket && !frame.isKeyframe {
            frame.isKeyframe = true
        }

        // NOTE: We intentionally do NOT discard older incomplete keyframes when a newer one starts.
        // During network congestion, multiple keyframes may arrive simultaneously. Discarding
        // partially-complete keyframes (even 70%+) in favor of new ones creates a cascade where
        // ALL keyframes fail. Instead, let each keyframe complete or timeout naturally via
        // cleanupOldFrames(). The timeout-based approach is more robust.

        // Store fragment
        frame.fragments[header.fragmentIndex] = data
        pendingFrames[frameNumber] = frame

        // Log keyframe assembly progress for diagnostics
        if frame.isKeyframe {
            let receivedCount = frame.fragments.count
            let totalCount = Int(frame.totalFragments)
            // Log at key milestones: first packet, 25%, 50%, 75%, and when nearly complete
            if receivedCount == 1 || receivedCount == totalCount / 4 || receivedCount == totalCount / 2 ||
               receivedCount == (totalCount * 3) / 4 || receivedCount == totalCount - 1 {
                MirageLogger.log(.frameAssembly, "Keyframe \(frameNumber): \(receivedCount)/\(totalCount) fragments received")
            }
        }

        // Check if frame is complete
        if frame.fragments.count == Int(frame.totalFragments) {
            completeFrame(frameNumber: frameNumber, frame: frame)
        }

        // Clean up old pending frames
        cleanupOldFrames()
    }

    private func completeFrame(frameNumber: UInt32, frame: PendingFrame) {
        // Reassemble fragments in order
        var completeData = Data()
        for i in 0..<frame.totalFragments {
            if let fragment = frame.fragments[i] {
                completeData.append(fragment)
            } else {
                // Missing fragment, can't complete
                MirageLogger.log(.frameAssembly, "Frame \(frameNumber) incomplete - missing fragment \(i)")
                pendingFrames.removeValue(forKey: frameNumber)
                droppedFrameCount += 1
                return
            }
        }

        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool

        if frame.isKeyframe {
            // Always deliver keyframes unless a newer keyframe was already delivered
            shouldDeliver = frameNumber > lastDeliveredKeyframe || lastDeliveredKeyframe == 0
            if shouldDeliver {
                lastDeliveredKeyframe = frameNumber
            }
        } else {
            // For P-frames: only deliver if newer than last completed frame
            // and after the last keyframe (decoder needs the reference)
            shouldDeliver = frameNumber > lastCompletedFrame && frameNumber > lastDeliveredKeyframe
        }

        if shouldDeliver {
            // Discard any pending frames older than this one
            discardOlderPendingFrames(olderThan: frameNumber)

            lastCompletedFrame = frameNumber
            pendingFrames.removeValue(forKey: frameNumber)

            framesDelivered += 1
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "Delivering keyframe \(frameNumber) (\(completeData.count) bytes)")
                awaitingKeyframe = false
            }
            onFrameComplete?(streamID, completeData, frame.isKeyframe, frame.timestamp, frame.contentRect)
        } else {
            // This frame arrived too late - a newer frame was already delivered
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "WARNING: Keyframe \(frameNumber) NOT delivered (lastDeliveredKeyframe=\(lastDeliveredKeyframe))")
            }
            pendingFrames.removeValue(forKey: frameNumber)
            droppedFrameCount += 1
        }
    }

    /// Discard pending P-frames older than the given frame number
    /// IMPORTANT: Never discard pending keyframes - they're critical for recovery
    /// and take longer to arrive due to their large size
    private func discardOlderPendingFrames(olderThan frameNumber: UInt32) {
        let framesToDiscard = pendingFrames.keys.filter { pendingFrameNumber in
            // Discard P-frames older than the one we're about to deliver
            // Handle wrap-around: if difference is huge, it's probably wrap-around
            guard pendingFrameNumber < frameNumber && frameNumber - pendingFrameNumber < 1000 else {
                return false
            }
            // NEVER discard pending keyframes - they're critical for decoder recovery
            // Keyframes are large (500+ packets) and take longer to arrive than P-frames
            // If we discard an incomplete keyframe, the decoder will be stuck
            if let frame = pendingFrames[pendingFrameNumber], frame.isKeyframe {
                return false
            }
            return true
        }

        for discardFrame in framesToDiscard {
            if pendingFrames[discardFrame] != nil {
                droppedFrameCount += 1
            }
            pendingFrames.removeValue(forKey: discardFrame)
        }
    }

    private func resetForEpoch(_ epoch: UInt16, reason: String) {
        currentEpoch = epoch
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        awaitingKeyframe = false
        packetsDiscardedAwaitingKeyframe = 0
        MirageLogger.log(.frameAssembly, "Epoch \(epoch) reset (\(reason)) for stream \(streamID)")
    }

    private func cleanupOldFrames() {
        let now = Date()
        // P-frame timeout: 500ms - allows time for UDP packet jitter without dropping frames
        let pFrameTimeout: TimeInterval = 0.5
        // Keyframe timeout: 3s - keyframes are 600-900 packets and critical for recovery
        // They need much more time to complete than small P-frames
        let keyframeTimeout: TimeInterval = 3.0

        var timedOutCount: UInt64 = 0
        pendingFrames = pendingFrames.filter { frameNumber, frame in
            let timeout = frame.isKeyframe ? keyframeTimeout : pFrameTimeout
            let shouldKeep = now.timeIntervalSince(frame.receivedAt) < timeout
            if !shouldKeep {
                // Log timeout with fragment completion info for debugging
                let receivedCount = frame.fragments.count
                let totalCount = frame.totalFragments
                let isKeyframe = frame.isKeyframe
                MirageLogger.log(.frameAssembly, "Frame \(frameNumber) timed out: \(receivedCount)/\(totalCount) fragments\(isKeyframe ? " (KEYFRAME)" : "")")
                timedOutCount += 1
            }
            return shouldKeep
        }
        droppedFrameCount += timedOutCount
    }

    /// Request a keyframe if too many frames are incomplete or dropped
    func shouldRequestKeyframe() -> Bool {
        let incompleteCount = pendingFrames.count
        return incompleteCount > 5
    }

    /// Get the number of dropped frames
    func getDroppedFrameCount() -> UInt64 {
        droppedFrameCount
    }

    /// Reset state for a new stream
    func reset() {
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        droppedFrameCount = 0
        awaitingKeyframe = false
        packetsDiscardedAwaitingKeyframe = 0
        currentEpoch = 0
        packetsDiscardedEpoch = 0
    }

    /// Enter keyframe-only mode after decoder errors until a keyframe arrives.
    func enterKeyframeOnlyMode() {
        awaitingKeyframe = true
        pendingFrames = pendingFrames.filter { $0.value.isKeyframe }
        MirageLogger.log(.frameAssembly, "Entering keyframe-only mode for stream \(streamID)")
    }
}
