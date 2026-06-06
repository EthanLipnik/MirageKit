//
//  VideoDecoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-accelerated video decoder using VideoToolbox (HEVC or ProRes)
actor VideoDecoder {
    var decompressionSession: VTDecompressionSession?
    var formatDescription: CMFormatDescription?
    var codec: MirageMedia.MirageVideoCodec = .hevc
    /// Stream dimensions for ProRes format description creation (set from stream started message)
    var proResStreamDimensions: (width: Int, height: Int)?
    var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    var preferredOutputColorDepth: MirageMedia.MirageStreamColorDepth = .standard
    var lastDecodedOutputPixelFormat: OSType?
    var maximizePowerEfficiencyEnabled = false
    var decompressionSessionGeneration: UInt64 = 0
    let decodeCallbackGenerationFence = DecodeCallbackGenerationFence()
    var pendingOutputTelemetryGeneration: UInt64 = 0
    var usingHardwareDecoder: Bool?
    var decoderHardwareStatusRefreshAttempts: Int = 0
    let maxDecoderHardwareStatusRefreshAttempts: Int = 4

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
    /// Thread-safe rate limiter for non-fatal VideoToolbox callback diagnostics.
    let callbackFailureLogLimiter = DecodeCallbackFailureLogLimiter()
    /// Consecutive decode errors allowed before requesting recovery.
    let maxConsecutiveErrors = 5
    /// Thread-safe decode performance tracker (updated from decode callback)
    let performanceTracker = DecodePerformanceTracker()

    /// Bounded in-flight decode submissions to avoid decoder saturation spirals.
    var decodeSubmissionLimit: Int = 1
    var inFlightDecodeSubmissions: Int = 0
    var decodeSubmissionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Handler called when video dimensions change - used to reset reassembler.
    var onDimensionChange: (@Sendable (_ frameNumber: UInt32?) -> Void)?

    /// When true, discard all P-frames and only process keyframes.
    /// Set when client initiates a resize request - P-frames at new dimensions will fail
    /// until we receive a keyframe with the new VPS/SPS/PPS parameter sets.
    var awaitingDimensionChange = false

    /// Time when dimension change started (for timeout detection)
    var dimensionChangeStartTime: CFAbsoluteTime = 0

    /// Timeout for awaiting dimension change (seconds) before re-requesting keyframe
    let dimensionChangeTimeout: CFAbsoluteTime = 2.0

    /// Minimum interval between invalid payload recovery signals.
    let invalidPayloadRecoveryCooldown: CFAbsoluteTime = 1.0
    var lastInvalidPayloadRecoveryTime: CFAbsoluteTime = 0

    /// Expected dimensions after resize (optional, for validation)
    var expectedDimensions: (width: Int, height: Int)?
}

extension VideoDecoder {
    func preferredOutputPixelFormat(for colorDepth: MirageMedia.MirageStreamColorDepth) -> OSType {
        switch colorDepth {
        case .standard:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .pro:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .ultra:
            return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        }
    }

    nonisolated static func isTenBitPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_ARGB2101010LEPacked:
            true
        default:
            false
        }
    }

    nonisolated static func isTenBit444PixelFormat(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    }

    nonisolated static func shouldWarnOutputFormatFallback(
        preferredColorDepth: MirageMedia.MirageStreamColorDepth,
        actualOutputPixelFormat: OSType
    )
    -> Bool {
        switch preferredColorDepth {
        case .standard:
            false
        case .pro:
            !isTenBitPixelFormat(actualOutputPixelFormat)
        case .ultra:
            !isTenBit444PixelFormat(actualOutputPixelFormat)
        }
    }

    nonisolated static func outputFormatRequirementName(for colorDepth: MirageMedia.MirageStreamColorDepth) -> String? {
        switch colorDepth {
        case .standard:
            nil
        case .pro:
            "10-bit"
        case .ultra:
            "10-bit 4:4:4"
        }
    }

    nonisolated static func pixelFormatName(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "420f (8-bit FullRange)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "420v (8-bit VideoRange)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return "x420 (10-bit FullRange)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return "xf20 (10-bit VideoRange)"
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return "xf44 (10-bit 4:4:4)"
        case kCVPixelFormatType_ARGB2101010LEPacked:
            return "l10r (ARGB2101010)"
        case kCVPixelFormatType_32BGRA:
            return "BGRA (8-bit)"
        default:
            let bytes = [
                UInt8((pixelFormat >> 24) & 0xFF),
                UInt8((pixelFormat >> 16) & 0xFF),
                UInt8((pixelFormat >> 8) & 0xFF),
                UInt8(pixelFormat & 0xFF),
            ]
            let label = String(bytes: bytes, encoding: .ascii) ?? "????"
            return "\(label) (\(pixelFormat))"
        }
    }

    nonisolated static func shouldRecreateSession(
        isFirstKeyframe: Bool,
        dimensionsChanged: Bool,
        parameterSetsChanged: Bool,
        shouldRecreateForErrors: Bool
    )
    -> Bool {
        guard !isFirstKeyframe else { return false }
        return dimensionsChanged || parameterSetsChanged || shouldRecreateForErrors
    }

    nonisolated static func callbackFailureName(for status: OSStatus) -> String {
        switch status {
        case -12909:
            "BadData"
        case -12911:
            "Malfunction"
        case -12903:
            "InvalidSession"
        case -12910:
            "UnsupportedDataFormat"
        case -17694:
            "ReferenceMissing"
        default:
            "Unknown"
        }
    }

    nonisolated static func shouldSuppressNonFatalCallbackFailure(status: OSStatus) -> Bool {
        switch status {
        case -12909,
             -12911,
             -12903,
             -12910,
             -17694:
            true
        default:
            false
        }
    }

    nonisolated static func shouldInvalidateSessionAfterCallbackFailure(status: OSStatus) -> Bool {
        switch status {
        case -12911,
             -12903:
            true
        default:
            false
        }
    }
}

/// Info passed through the decode callback
final class DecodeInfo: @unchecked Sendable {
    let handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?
    let contentRect: CGRect
    let isKeyframe: Bool
    let errorTracker: DecodeErrorTracker?
    let decodeStartTime: CFAbsoluteTime
    let performanceTracker: DecodePerformanceTracker?
    let callbackFailureLogLimiter: DecodeCallbackFailureLogLimiter?
    let sessionGeneration: UInt64
    let colorDepth: MirageMedia.MirageStreamColorDepth
    let onCompletion: (@Sendable () -> Void)?

    init(
        handler: (@Sendable (CVPixelBuffer, CMTime, CGRect) -> Void)?,
        contentRect: CGRect,
        isKeyframe: Bool,
        errorTracker: DecodeErrorTracker?,
        decodeStartTime: CFAbsoluteTime,
        performanceTracker: DecodePerformanceTracker?,
        callbackFailureLogLimiter: DecodeCallbackFailureLogLimiter?,
        sessionGeneration: UInt64,
        colorDepth: MirageMedia.MirageStreamColorDepth,
        onCompletion: (@Sendable () -> Void)?
    ) {
        self.handler = handler
        self.contentRect = contentRect
        self.isKeyframe = isKeyframe
        self.errorTracker = errorTracker
        self.decodeStartTime = decodeStartTime
        self.performanceTracker = performanceTracker
        self.callbackFailureLogLimiter = callbackFailureLogLimiter
        self.sessionGeneration = sessionGeneration
        self.colorDepth = colorDepth
        self.onCompletion = onCompletion
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
    var recoveryRequiresKeyframeDecode = false
    var nonKeyframesSkippedForRecovery: UInt64 = 0

    /// Minimum time between keyframe requests (seconds)
    /// Keeps retries aligned with keyframe assembly timeouts
    let retryInterval: CFAbsoluteTime = 3.0

    /// Number of errors to accumulate before retrying after initial request
    /// 10 errors balances fast retry with avoiding excessive keyframe requests
    let retryErrorThreshold: Int = 10
    /// Minimum spacing between threshold dispatches across recovery episodes.
    let thresholdDispatchCooldown: CFAbsoluteTime = 1.0

    /// Flag indicating session recreation has been attempted for current error episode.
    /// Set when session is recreated, cleared on successful decode.
    /// Prevents rapid recreation on consecutive keyframes.
    var sessionRecreationAttempted = false

    /// Synthetic recovery-tracking state used for resize stabilization windows.
    /// When armed, a short streak of successful decode callbacks is required before
    /// the tracker reports recovery complete through `onRecovery`.
    var recoveryTrackingArmed = false

    /// Time of last session recreation attempt (for cooldown)
    var lastSessionRecreationTime: CFAbsoluteTime = 0

    /// Minimum time between session recreations (seconds)
    let sessionRecreationCooldown: CFAbsoluteTime = 2.0

    /// Require a short run of successful decode callbacks before clearing recovery state.
    let recoverySuccessThreshold: Int = 3
    var recoverySuccessCount: Int = 0

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
