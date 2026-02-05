//
//  HEVCDecoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

/// Hardware-accelerated HEVC decoder using VideoToolbox
actor HEVCDecoder {
    var decompressionSession: VTDecompressionSession?
    var formatDescription: CMFormatDescription?
    var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// Cached parameter sets for resilience against corrupted keyframes
    /// When a keyframe fails to parse, we can continue with cached format description
    var cachedVPS: Data?
    var cachedSPS: Data?
    var cachedPPS: Data?
    var cachedFormatDescription: CMFormatDescription?

    let memoryPoolAgeOutSeconds: TimeInterval = 1.0
    var memoryPool: CMMemoryPool?

    var isDecoding = false
    var decodedFrameHandler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?

    /// Thread-safe error tracker for decode callbacks
    var errorTracker: DecodeErrorTracker?
    /// Reduced from 15 to 5 for faster recovery from decode errors
    let maxConsecutiveErrors = 5
    /// Thread-safe decode performance tracker (updated from decode callback)
    let performanceTracker = DecodePerformanceTracker()

    /// Handler called when video dimensions change - used to reset reassembler
    var onDimensionChange: (@Sendable () -> Void)?

    /// Handler called when input blocking state changes (true = block input, false = allow input)
    /// Input should be blocked when decoder is awaiting keyframe or has decode errors
    var onInputBlockingChanged: (@Sendable (Bool) -> Void)?

    /// When true, discard all P-frames and only process keyframes.
    /// Set when client initiates a resize request - P-frames at new dimensions will fail
    /// until we receive a keyframe with the new VPS/SPS/PPS parameter sets.
    var awaitingDimensionChange = false

    /// Time when dimension change started (for timeout detection)
    var dimensionChangeStartTime: CFAbsoluteTime = 0

    /// Timeout for awaiting dimension change (seconds) before re-requesting keyframe
    let dimensionChangeTimeout: CFAbsoluteTime = 2.0

    /// Expected dimensions after resize (optional, for validation)
    var expectedDimensions: (width: Int, height: Int)?

    // Set handler called when decode errors exceed threshold, indicating need for keyframe

    // Set handler called when video dimensions change
    // Used to reset the reassembler and discard pending old-dimension fragments

    // Set handler called when input blocking state changes
    // Input should be blocked when decoder is in a bad state (awaiting keyframe, decode errors)

    // Get the current average decode time (ms) from recent samples.

    // Get the total decode error count (lifetime).

    // Called when client initiates a resize request.
    // Puts decoder in "awaiting dimension change" mode where P-frames are discarded
    // until a keyframe with new VPS/SPS/PPS arrives.

    // Clear any stuck state that prevents frame processing.
    // Called when recovering from app backgrounding to ensure decoder accepts new frames.

    // Start decoding with a frame handler

    // Stop decoding

    // Reset the decoder state for a new stream session (e.g., after resize or reconnection).
    // Clears cached VPS/SPS/PPS so the next keyframe will be used to configure the decoder.
    // Unlike stopDecoding(), this keeps the decoder running and ready to receive new frames.

    // Decode an encoded frame

    // Extract format description from parameter sets and return data with parameter sets stripped

    // Strip leading SEI NAL units from AVCC data
    // SEI NAL types: 39 (PREFIX_SEI_NUT), 40 (SUFFIX_SEI_NUT)
    // Note: SEI contains HDR metadata but VideoToolbox may not decode properly if SEI precedes IDR

    // Find where AVCC data begins after the last Annex B NAL unit (PPS)
    // AVCC uses 4-byte big-endian length prefixes instead of start codes

    // Parse NAL units from Annex B data and return with end positions

    // Parse NAL units from Annex B or length-prefixed data

    // Flush pending frames
}

/// Info passed through the decode callback
final class DecodeInfo: @unchecked Sendable {
    let handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?
    let contentRect: CGRect
    let errorTracker: DecodeErrorTracker?
    let decodeStartTime: CFAbsoluteTime
    let performanceTracker: DecodePerformanceTracker?
    let releaseBuffer: (@Sendable () -> Void)?
    let data: Data

    init(
        handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?,
        contentRect: CGRect,
        errorTracker: DecodeErrorTracker?,
        decodeStartTime: CFAbsoluteTime,
        performanceTracker: DecodePerformanceTracker?,
        releaseBuffer: (@Sendable () -> Void)?,
        data: Data
    ) {
        self.handler = handler
        self.contentRect = contentRect
        self.errorTracker = errorTracker
        self.decodeStartTime = decodeStartTime
        self.performanceTracker = performanceTracker
        self.releaseBuffer = releaseBuffer
        self.data = data
    }
}

/// Thread-safe error tracker for decode callbacks
/// Used to detect when decoder enters a bad state and needs a keyframe
final class DecodeErrorTracker: @unchecked Sendable {
    let lock = NSLock()
    var consecutiveErrors: Int = 0
    let maxConsecutiveErrors: Int
    let onThresholdReached: @Sendable () -> Void
    let onRecovery: (@Sendable () -> Void)?
    var thresholdFired = false
    var lastThresholdTime: CFAbsoluteTime = 0
    var totalErrors: UInt64 = 0

    /// Minimum time between keyframe requests (seconds)
    /// Keeps retries aligned with keyframe assembly timeouts
    let retryInterval: CFAbsoluteTime = 3.0

    /// Number of errors to accumulate before retrying after initial request
    /// 10 errors balances fast retry with avoiding excessive keyframe requests
    let retryErrorThreshold: Int = 10

    /// Flag indicating session recreation has been attempted for current error episode.
    /// Set when session is recreated, cleared on successful decode.
    /// Prevents rapid recreation on consecutive keyframes.
    var sessionRecreationAttempted = false

    /// Time of last session recreation attempt (for cooldown)
    var lastSessionRecreationTime: CFAbsoluteTime = 0

    /// Minimum time between session recreations (seconds)
    let sessionRecreationCooldown: CFAbsoluteTime = 2.0

    init(
        maxErrors: Int,
        onThresholdReached: @escaping @Sendable () -> Void,
        onRecovery: (@Sendable () -> Void)? = nil
    ) {
        maxConsecutiveErrors = maxErrors
        self.onThresholdReached = onThresholdReached
        self.onRecovery = onRecovery
    }

    // Record a decode error. Returns true if threshold was just exceeded.

    // Record a successful decode, resetting the error counter

    // Request keyframe immediately due to dimension change
    // This is more urgent than error-based requests - dimensions changed so ALL old frames will fail

    // Check if session recreation should be attempted on keyframe receipt.
    // Returns true only if:
    // 1. We've had decode errors (thresholdFired or consecutiveErrors > 0)
    // 2. Session recreation hasn't been attempted yet OR cooldown has passed

    // Mark that session has been recreated.
    // Called after decoder recreates session on keyframe.

    // Clear error tracking state for dimension change.
    // Called when dimensions change to give the decoder a clean slate.
    // Unlike markSessionRecreated(), this doesn't impose a cooldown since
    // dimension changes inherently require a fresh session anyway.
}

/// Thread-safe decode timing tracker for recent samples
final class DecodePerformanceTracker: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Double] = []
    let maxSamples: Int = 30
}

/// Reassembles video frames from network packets.
/// Uses lock-based synchronization to avoid per-packet Task overhead.
final class FrameReassembler: @unchecked Sendable {
    struct Metrics: Sendable {
        let framesDelivered: UInt64
        let droppedFrames: UInt64
    }
    /// The stream ID this reassembler handles
    let streamID: StreamID
    let maxPayloadSize: Int
    let lock = NSLock()
    let bufferPool = FrameBufferPool()

    var pendingFrames: [UInt32: PendingFrame] = [:]
    var lastCompletedFrame: UInt32 = 0
    var lastDeliveredKeyframe: UInt32 = 0
    var droppedFrameCount: UInt64 = 0
    var awaitingKeyframe: Bool = false
    var awaitingKeyframeSince: CFAbsoluteTime = 0
    var currentEpoch: UInt16 = 0
    let keyframeTimeout: TimeInterval = 3.0

    /// Expected dimension token - frames with mismatched tokens are silently discarded.
    /// Updated when stream starts or client receives a resize notification.
    /// Initial value of 0 accepts all frames until explicitly set.
    var expectedDimensionToken: UInt16 = 0

    /// Whether dimension token validation is enabled.
    /// Disabled by default to maintain backward compatibility with older hosts.
    var dimensionTokenValidationEnabled: Bool = false

    /// Frame completion callback: (streamID, frameData, isKeyframe, timestamp, contentRect, release)
    var onFrameComplete: (@Sendable (StreamID, Data, Bool, UInt64, CGRect, @escaping @Sendable () -> Void) -> Void)?

    // MARK: - Diagnostic counters

    var totalPacketsReceived: UInt64 = 0
    var framesDelivered: UInt64 = 0
    var packetsDiscardedOld: UInt64 = 0
    var packetsDiscardedCRC: UInt64 = 0
    var packetsDiscardedToken: UInt64 = 0
    var packetsDiscardedAwaitingKeyframe: UInt64 = 0
    var packetsDiscardedEpoch: UInt64 = 0
    var lastStatsLog: UInt64 = 0
    let keyframeFECBlockSize: Int = 8
    let pFrameFECBlockSize: Int = 16

    /// Callback for loss events (frame timeouts).
    var onFrameLoss: (@Sendable (StreamID) -> Void)?

    final class PendingFrame {
        let buffer: FrameBufferPool.Buffer
        var receivedMap: [Bool]
        var receivedCount: Int
        let totalFragments: UInt16
        let dataFragmentCount: Int
        var isKeyframe: Bool
        let timestamp: UInt64
        let receivedAt: Date
        let contentRect: CGRect
        var expectedTotalBytes: Int
        var parityFragments: [Int: Data]
        var receivedParityCount: Int

        init(
            buffer: FrameBufferPool.Buffer,
            receivedMap: [Bool],
            receivedCount: Int,
            totalFragments: UInt16,
            dataFragmentCount: Int,
            isKeyframe: Bool,
            timestamp: UInt64,
            receivedAt: Date,
            contentRect: CGRect,
            expectedTotalBytes: Int,
            parityFragments: [Int: Data] = [:],
            receivedParityCount: Int = 0
        ) {
            self.buffer = buffer
            self.receivedMap = receivedMap
            self.receivedCount = receivedCount
            self.totalFragments = totalFragments
            self.dataFragmentCount = dataFragmentCount
            self.isKeyframe = isKeyframe
            self.timestamp = timestamp
            self.receivedAt = receivedAt
            self.contentRect = contentRect
            self.expectedTotalBytes = expectedTotalBytes
            self.parityFragments = parityFragments
            self.receivedParityCount = receivedParityCount
        }
    }

    init(streamID: StreamID, maxPayloadSize: Int) {
        self.streamID = streamID
        self.maxPayloadSize = max(1, maxPayloadSize)
    }

    // Update the expected dimension token for this stream.
    // Frames with mismatched tokens will be silently discarded.
    // Called when stream starts or when client is notified of a resize.
    // - Parameter token: The new expected dimension token from the host

    // Process a received packet

    // Discard pending P-frames older than the given frame number
    // IMPORTANT: Never discard pending keyframes - they're critical for recovery
    // and take longer to arrive due to their large size

    // Request a keyframe if too many frames are incomplete or dropped

    // Get the number of dropped frames

    // Reset state for a new stream

    // Enter keyframe-only mode after decoder errors until a keyframe arrives.
}
