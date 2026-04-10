//
//  MirageClientFastPathState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation
import MirageKit

final class MirageClientFastPathState: @unchecked Sendable {
    struct VideoPacketContext {
        let consumedStartupPending: Bool
        let reassembler: FrameReassembler?
        let mediaPacketKey: MirageMediaPacketKey?
    }

    struct AudioPacketContext {
        let targetChannelCount: Int
        let mediaPacketKey: MirageMediaPacketKey?
    }

    private struct State {
        var mediaSecurityContext: MirageMediaSecurityContext?
        var mediaSecurityPacketKey: MirageMediaPacketKey?
        var activeAudioStreamID: StreamID?
        var audioDecodeTargetChannelCount: Int = 2
        var qualityTestAccumulator: QualityTestAccumulator?
        var qualityTestActiveTestID: UUID?
        var activeStreamIDs: Set<StreamID> = []
        var startupPacketPending: Set<StreamID> = []
        var reassemblersByStream: [StreamID: FrameReassembler] = [:]
        var observedMediaStreamLabels: Set<String> = []
        var firstVideoPacketRejectionReasonByStream: [StreamID: IncomingVideoPacketRejectionReason] = [:]
        var lastInboundControlActivityTime: CFAbsoluteTime = 0
        var lastInboundMediaActivityTime: CFAbsoluteTime = 0
    }

    private let lock = NSLock()
    private var state = State()

    func activeStreamIDsSnapshot() -> Set<StreamID> {
        withLock { $0.activeStreamIDs }
    }

    func addActiveStreamID(_ id: StreamID) {
        withLock { $0.activeStreamIDs.insert(id) }
    }

    func removeActiveStreamID(_ id: StreamID) {
        withLock { $0.activeStreamIDs.remove(id) }
    }

    func clearActiveStreamIDs() {
        withLock { $0.activeStreamIDs.removeAll() }
    }

    func videoPacketContext(for streamID: StreamID) -> VideoPacketContext? {
        withLock { state in
            guard state.activeStreamIDs.contains(streamID) else { return nil }
            let consumedStartupPending = state.startupPacketPending.remove(streamID) != nil
            return VideoPacketContext(
                consumedStartupPending: consumedStartupPending,
                reassembler: state.reassemblersByStream[streamID],
                mediaPacketKey: state.mediaSecurityPacketKey
            )
        }
    }

    func setReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        withLock { $0.reassemblersByStream = snapshot }
    }

    func setMediaSecurityContext(_ context: MirageMediaSecurityContext?) {
        withLock { state in
            state.mediaSecurityContext = context
            state.mediaSecurityPacketKey = context.map { MirageMediaSecurity.makePacketKey(context: $0) }
        }
    }

    func mediaSecurityContext() -> MirageMediaSecurityContext? {
        withLock { $0.mediaSecurityContext }
    }

    func mediaSecurityPacketKey() -> MirageMediaPacketKey? {
        withLock { $0.mediaSecurityPacketKey }
    }

    func setActiveAudioStreamID(_ streamID: StreamID?) {
        withLock { $0.activeAudioStreamID = streamID }
    }

    func setAudioDecodeTargetChannelCount(_ count: Int) {
        withLock { $0.audioDecodeTargetChannelCount = max(1, count) }
    }

    func audioPacketContext(for streamID: StreamID) -> AudioPacketContext? {
        withLock { state in
            guard state.activeAudioStreamID == streamID else { return nil }
            return AudioPacketContext(
                targetChannelCount: max(1, state.audioDecodeTargetChannelCount),
                mediaPacketKey: state.mediaSecurityPacketKey
            )
        }
    }

    func markStartupPacketPending(_ streamID: StreamID) {
        withLock { $0.startupPacketPending.insert(streamID) }
    }

    func clearStartupPacketPending(_ streamID: StreamID) {
        withLock { $0.startupPacketPending.remove(streamID) }
    }

    func clearAllStartupPacketPending() {
        withLock { $0.startupPacketPending.removeAll() }
    }

    func isStartupPacketPending(_ streamID: StreamID) -> Bool {
        withLock { $0.startupPacketPending.contains(streamID) }
    }

    func markObservedMediaStreamLabel(_ label: String) -> Bool {
        withLock { state in
            state.observedMediaStreamLabels.insert(label).inserted
        }
    }

    func markFirstVideoPacketRejectionReason(
        _ reason: IncomingVideoPacketRejectionReason,
        for streamID: StreamID
    ) -> Bool {
        withLock { state in
            guard state.firstVideoPacketRejectionReasonByStream[streamID] == nil else {
                return false
            }
            state.firstVideoPacketRejectionReasonByStream[streamID] = reason
            return true
        }
    }

    func clearDiagnostics() {
        withLock { state in
            state.observedMediaStreamLabels.removeAll()
            state.firstVideoPacketRejectionReasonByStream.removeAll()
        }
    }

    func noteInboundControlActivity(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        withLock { $0.lastInboundControlActivityTime = now }
    }

    func noteInboundMediaActivity(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        withLock { $0.lastInboundMediaActivityTime = now }
    }

    func latestInboundActivityTime() -> CFAbsoluteTime {
        withLock { max($0.lastInboundControlActivityTime, $0.lastInboundMediaActivityTime) }
    }

    func resetInboundActivity(now: CFAbsoluteTime = 0) {
        withLock { state in
            state.lastInboundControlActivityTime = now
            state.lastInboundMediaActivityTime = now
        }
    }

    func qualityTestContext() -> (accumulator: QualityTestAccumulator?, testID: UUID?) {
        withLock { state in
            (state.qualityTestAccumulator, state.qualityTestActiveTestID)
        }
    }

    func setQualityTestAccumulator(_ accumulator: QualityTestAccumulator, testID: UUID) {
        withLock { state in
            state.qualityTestAccumulator = accumulator
            state.qualityTestActiveTestID = testID
        }
    }

    func clearQualityTestAccumulator() {
        withLock { state in
            state.qualityTestAccumulator = nil
            state.qualityTestActiveTestID = nil
        }
    }

    @discardableResult
    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
