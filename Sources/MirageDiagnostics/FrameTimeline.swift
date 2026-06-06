//
//  FrameTimeline.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

/// Dependency epoch associated with a decoded frame timeline.
package struct DependencyEpoch: Sendable, Equatable, Hashable, Comparable {
    package let rawValue: UInt16

    package init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static func < (lhs: DependencyEpoch, rhs: DependencyEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Client-side reason a frame left the decode-to-render timeline before display.
package enum FrameDropReason: String, Sendable, Equatable {
    case stalePacket
    case payloadIntegrity
    case awaitingKeyframe
    case epochMismatch
    case timeout
    case memoryBudget
    case decodeBacklog
    case decodeQueueEviction
    case decodeFailure
    case malformedKeyframe
    case rendererQueueEviction
    case staleRendererFrame
    case generationMismatch
}

/// Internal per-frame timeline model for realtime stream diagnostics.
package struct FrameTimeline: Sendable, Equatable {
    package let streamID: StreamID
    package let frameNumber: UInt32
    package var dependencyEpoch: DependencyEpoch
    package var isKeyframe: Bool
    package var encodedByteCount: Int
    package var fragmentCount: Int
    package var receivedFragmentCount: Int
    package var firstPacketReceiveTime: CFAbsoluteTime?
    package var lastPacketReceiveTime: CFAbsoluteTime?
    package var reassemblyCompleteTime: CFAbsoluteTime?
    package var decodeSubmitTime: CFAbsoluteTime?
    package var decodeCallbackTime: CFAbsoluteTime?
    package var renderEnqueueTime: CFAbsoluteTime?
    package var displayPresentationAcceptedTime: CFAbsoluteTime?
    package var queueAgeMs: Double
    package var dropReason: FrameDropReason?

    package init(
        streamID: StreamID,
        frameNumber: UInt32,
        dependencyEpoch: DependencyEpoch,
        isKeyframe: Bool,
        encodedByteCount: Int,
        fragmentCount: Int,
        receivedFragmentCount: Int = 0,
        firstPacketReceiveTime: CFAbsoluteTime? = nil,
        lastPacketReceiveTime: CFAbsoluteTime? = nil,
        reassemblyCompleteTime: CFAbsoluteTime? = nil,
        decodeSubmitTime: CFAbsoluteTime? = nil,
        decodeCallbackTime: CFAbsoluteTime? = nil,
        renderEnqueueTime: CFAbsoluteTime? = nil,
        displayPresentationAcceptedTime: CFAbsoluteTime? = nil,
        queueAgeMs: Double = 0,
        dropReason: FrameDropReason? = nil
    ) {
        self.streamID = streamID
        self.frameNumber = frameNumber
        self.dependencyEpoch = dependencyEpoch
        self.isKeyframe = isKeyframe
        self.encodedByteCount = encodedByteCount
        self.fragmentCount = fragmentCount
        self.receivedFragmentCount = receivedFragmentCount
        self.firstPacketReceiveTime = firstPacketReceiveTime
        self.lastPacketReceiveTime = lastPacketReceiveTime
        self.reassemblyCompleteTime = reassemblyCompleteTime
        self.decodeSubmitTime = decodeSubmitTime
        self.decodeCallbackTime = decodeCallbackTime
        self.renderEnqueueTime = renderEnqueueTime
        self.displayPresentationAcceptedTime = displayPresentationAcceptedTime
        self.queueAgeMs = queueAgeMs
        self.dropReason = dropReason
    }

    package func markingPacketReceived(
        at time: CFAbsoluteTime,
        receivedFragmentCount: Int
    ) -> FrameTimeline {
        var copy = self
        if copy.firstPacketReceiveTime == nil {
            copy.firstPacketReceiveTime = time
        }
        copy.lastPacketReceiveTime = time
        copy.receivedFragmentCount = max(copy.receivedFragmentCount, receivedFragmentCount)
        return copy
    }

    package func markingReassembled(
        at time: CFAbsoluteTime,
        byteCount: Int,
        receivedFragmentCount: Int,
        queueAgeMs: Double
    ) -> FrameTimeline {
        var copy = markingPacketReceived(at: time, receivedFragmentCount: receivedFragmentCount)
        copy.reassemblyCompleteTime = time
        copy.encodedByteCount = max(copy.encodedByteCount, byteCount)
        copy.queueAgeMs = max(0, queueAgeMs)
        return copy
    }

    package func markingDecodeSubmitted(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.decodeSubmitTime = time
        return copy
    }

    package func markingDecodeCallback(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.decodeCallbackTime = time
        return copy
    }

    package func markingRenderEnqueued(at time: CFAbsoluteTime, queueAgeMs: Double) -> FrameTimeline {
        var copy = self
        copy.renderEnqueueTime = time
        copy.queueAgeMs = max(copy.queueAgeMs, max(0, queueAgeMs))
        return copy
    }

    package func markingDisplayAccepted(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.displayPresentationAcceptedTime = time
        return copy
    }

    package func markingDropped(_ reason: FrameDropReason, at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.lastPacketReceiveTime = copy.lastPacketReceiveTime ?? time
        copy.dropReason = reason
        return copy
    }
}
