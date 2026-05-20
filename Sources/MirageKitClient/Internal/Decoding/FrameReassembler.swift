//
//  FrameReassembler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Root state for client video frame reassembly.
//

import CoreGraphics
import Foundation
import MirageKit

/// Reassembles video frames from network packets.
/// Uses lock-based synchronization to avoid per-packet Task overhead.
final class FrameReassembler: @unchecked Sendable {
    enum FrameLossReason: String, Sendable, Equatable {
        case timeout
        case forwardGapTimeout
        case memoryBudget
        case severeForwardGap

        var requestsImmediateActiveRecovery: Bool {
            switch self {
            case .timeout:
                false
            case .forwardGapTimeout,
                 .severeForwardGap:
                true
            case .memoryBudget:
                false
            }
        }
    }

    struct MemoryBudget: Sendable, Equatable {
        static let `default` = MemoryBudget(
            maxPendingFrames: 60,
            maxPendingKeyframes: 2,
            maxPendingBytes: 128 * 1024 * 1024
        )

        let maxPendingFrames: Int
        let maxPendingKeyframes: Int
        let maxPendingBytes: Int

        init(
            maxPendingFrames: Int,
            maxPendingKeyframes: Int,
            maxPendingBytes: Int
        ) {
            self.maxPendingFrames = max(1, maxPendingFrames)
            self.maxPendingKeyframes = max(1, maxPendingKeyframes)
            self.maxPendingBytes = max(1, maxPendingBytes)
        }
    }

    struct Metrics: Sendable {
        let droppedFrames: UInt64
        let pendingFrameCount: Int
        let pendingKeyframeCount: Int
        let pendingFrameBytes: Int
        let frameBufferPoolRetainedBytes: Int
        let budgetEvictions: UInt64
        let incompleteFrameTimeouts: UInt64
        let incompleteFrameNoProgressTimeouts: UInt64
        let incompleteFrameLifetimeTimeouts: UInt64
        let missingFragmentTimeouts: UInt64
        let forwardGapTimeouts: UInt64
        let pFrameCompletionLatencyP50Ms: Double
        let pFrameCompletionLatencyP95Ms: Double
        let pFrameCompletionLatencyMaxMs: Double
        let latePFrameCompletionCount: UInt64
    }

    struct PFrameCompletionLatencySample: Sendable {
        let completedAt: Date
        let latencyMs: Double
    }

    struct MemoryTrimResult: Sendable, Equatable {
        let evictedFrames: Int
        let releasedPendingBytes: Int
        let purgedRetainedBytes: Int
    }

    /// The stream ID this reassembler handles.
    let streamID: StreamID
    let maxPayloadSize: Int
    let lock = NSLock()
    let bufferPool = FrameBufferPool()
    let memoryBudget: MemoryBudget

    var pendingFrames: [UInt32: PendingFrame] = [:]
    var lastCompletedFrame: UInt32 = 0
    var lastDeliveredKeyframe: UInt32 = 0
    /// Tracks whether we have a valid keyframe anchor.
    /// Frame number 0 is valid, so lastDeliveredKeyframe cannot be used as a sentinel.
    var hasDeliveredKeyframeAnchor: Bool = false
    var droppedFrameCount: UInt64 = 0
    var memoryBudgetEvictionCount: UInt64 = 0
    var incompleteFrameTimeoutCount: UInt64 = 0
    var incompleteFrameNoProgressTimeoutCount: UInt64 = 0
    var incompleteFrameLifetimeTimeoutCount: UInt64 = 0
    var missingFragmentTimeoutCount: UInt64 = 0
    var forwardGapTimeoutCount: UInt64 = 0
    var awaitingKeyframe: Bool = false
    var awaitingKeyframeSince: CFAbsoluteTime = 0
    var lastPacketReceivedTime: CFAbsoluteTime = 0
    var currentEpoch: UInt16 = 0
    let keyframeTimeout: TimeInterval = 3.0
    let startupKeyframeTimeout: TimeInterval = 5.0
    let pendingKeyframePromotionDelay: TimeInterval = 0.15
    let pendingKeyframePromotionProgressThreshold: Double = 0.25
    let pendingKeyframeProgressPreservationThreshold: Double = 0.75
    let pFrameNoProgressTimeout: TimeInterval = 0.30
    let pFrameAbsoluteLifetimeCapDefault: TimeInterval = 0.60
    let pFrameAbsoluteLifetimeCapRemoteSmoothest: TimeInterval = 0.90
    let pFrameCompletionLatencySampleWindow: TimeInterval = 5.0
    let pFrameLateCompletionThresholdMs: Double = 250
    var targetFrameRate: Int = 60
    var latencyMode: MirageStreamLatencyMode = .lowestLatency
    var transportPathKind: MirageNetworkPathKind = .unknown
    var startupKeyframeTimeoutOverrideEnabled = false

    /// Expected dimension token; frames with mismatched tokens are silently discarded.
    /// Initial value of zero accepts all frames until explicitly set.
    var expectedDimensionToken: UInt16 = 0

    /// Whether dimension token validation is enabled.
    /// Disabled until the stream provides an explicit token contract.
    var dimensionTokenValidationEnabled: Bool = false

    /// Callback invoked when a frame is reassembled and ready for decode.
    var onFrameComplete: (@Sendable (StreamID, Data, Bool, UInt32, UInt64, CGRect, @escaping @Sendable () -> Void) -> Void)?

    var onFrameCompleteWithProvenance: (@Sendable (
        StreamID,
        Data,
        Bool,
        UInt32,
        UInt64,
        UInt16,
        UInt16,
        CGRect,
        @escaping @Sendable () -> Void
    ) -> Void)?

    // MARK: - Diagnostic counters

    var totalPacketsReceived: UInt64 = 0
    var packetsDiscardedCRC: UInt64 = 0

    /// Callback for loss events such as frame timeouts or pathological forward gaps.
    var onFrameLoss: (@Sendable (StreamID, FrameLossReason) -> Void)?

    /// Prevents repeated frame-loss signals for the same forward gap.
    var hasSignaledGapFrameLoss: Bool = false
    var pFrameCompletionLatencySamples: [PFrameCompletionLatencySample] = []

    final class PendingFrame {
        let buffer: FrameBufferPool.Buffer
        var receivedMap: [Bool]
        var receivedCount: Int
        var isComplete: Bool
        let totalFragments: UInt16
        let dataFragmentCount: Int
        let fecBlockSize: Int
        var isKeyframe: Bool
        let timestamp: UInt64
        let epoch: UInt16
        let dimensionToken: UInt16
        let receivedAt: Date
        var lastProgressAt: Date
        let contentRect: CGRect
        var expectedTotalBytes: Int
        var parityFragments: [Int: Data]
        var receivedParityCount: Int
        var retainedMemoryBytes: Int {
            buffer.capacity + parityFragments.values.reduce(0) { $0 + $1.count }
        }

        init(
            buffer: FrameBufferPool.Buffer,
            receivedMap: [Bool],
            receivedCount: Int,
            isComplete: Bool = false,
            totalFragments: UInt16,
            dataFragmentCount: Int,
            fecBlockSize: Int,
            isKeyframe: Bool,
            timestamp: UInt64,
            epoch: UInt16,
            dimensionToken: UInt16,
            receivedAt: Date,
            lastProgressAt: Date,
            contentRect: CGRect,
            expectedTotalBytes: Int,
            parityFragments: [Int: Data] = [:],
            receivedParityCount: Int = 0
        ) {
            self.buffer = buffer
            self.receivedMap = receivedMap
            self.receivedCount = receivedCount
            self.isComplete = isComplete
            self.totalFragments = totalFragments
            self.dataFragmentCount = dataFragmentCount
            self.fecBlockSize = fecBlockSize
            self.isKeyframe = isKeyframe
            self.timestamp = timestamp
            self.epoch = epoch
            self.dimensionToken = dimensionToken
            self.receivedAt = receivedAt
            self.lastProgressAt = lastProgressAt
            self.contentRect = contentRect
            self.expectedTotalBytes = expectedTotalBytes
            self.parityFragments = parityFragments
            self.receivedParityCount = receivedParityCount
        }
    }

    init(
        streamID: StreamID,
        maxPayloadSize: Int,
        memoryBudget: MemoryBudget = .default
    ) {
        self.streamID = streamID
        self.maxPayloadSize = max(1, maxPayloadSize)
        self.memoryBudget = memoryBudget
    }
}
