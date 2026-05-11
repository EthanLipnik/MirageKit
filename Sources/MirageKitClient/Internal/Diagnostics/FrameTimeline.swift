//
//  FrameTimeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Internal per-frame timeline model for realtime stream diagnostics.
//

import Foundation
import MirageKit

struct DependencyEpoch: Sendable, Equatable, Hashable, Comparable {
    let rawValue: UInt16

    init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static func < (lhs: DependencyEpoch, rhs: DependencyEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum FrameDropReason: String, Sendable, Equatable {
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

struct FrameTimeline: Sendable, Equatable {
    let streamID: StreamID
    let frameNumber: UInt32
    var dependencyEpoch: DependencyEpoch
    var isKeyframe: Bool
    var encodedByteCount: Int
    var fragmentCount: Int
    var receivedFragmentCount: Int
    var firstPacketReceiveTime: CFAbsoluteTime?
    var lastPacketReceiveTime: CFAbsoluteTime?
    var reassemblyCompleteTime: CFAbsoluteTime?
    var decodeSubmitTime: CFAbsoluteTime?
    var decodeCallbackTime: CFAbsoluteTime?
    var renderEnqueueTime: CFAbsoluteTime?
    var displayPresentationAcceptedTime: CFAbsoluteTime?
    var queueAgeMs: Double
    var dropReason: FrameDropReason?

    init(
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

    func markingPacketReceived(
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

    func markingReassembled(
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

    func markingDecodeSubmitted(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.decodeSubmitTime = time
        return copy
    }

    func markingDecodeCallback(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.decodeCallbackTime = time
        return copy
    }

    func markingRenderEnqueued(at time: CFAbsoluteTime, queueAgeMs: Double) -> FrameTimeline {
        var copy = self
        copy.renderEnqueueTime = time
        copy.queueAgeMs = max(copy.queueAgeMs, max(0, queueAgeMs))
        return copy
    }

    func markingDisplayAccepted(at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.displayPresentationAcceptedTime = time
        return copy
    }

    func markingDropped(_ reason: FrameDropReason, at time: CFAbsoluteTime) -> FrameTimeline {
        var copy = self
        copy.lastPacketReceiveTime = copy.lastPacketReceiveTime ?? time
        copy.dropReason = reason
        return copy
    }
}
