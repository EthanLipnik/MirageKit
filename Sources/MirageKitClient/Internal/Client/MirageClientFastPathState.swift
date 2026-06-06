//
//  MirageClientFastPathState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
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
import Foundation

final class MirageClientFastPathState: @unchecked Sendable {
    struct VideoPacketContext {
        let consumedStartupPending: Bool
        let reassembler: FrameReassembler?
        let mosaicReassembler: StreamControllerMosaicMediaUnitReassembler
        let mosaicPipeline: StreamControllerMosaicClientPipeline
        let mosaicTilePlan: MirageMosaicTilePlan?
        let mosaicContentRect: CGRect
        let mediaPacketKey: MirageMediaPacketKey?
    }

    struct AudioPacketContext {
        let targetChannelCount: Int
        let mediaPacketKey: MirageMediaPacketKey?
    }

    private struct State {
        var mediaSecurityPacketKey: MirageMediaPacketKey?
        var activeAudioStreamID: StreamID?
        var audioDecodeTargetChannelCount: Int = 2
        var activeStreamIDs: Set<StreamID> = []
        var startupPacketPending: Set<StreamID> = []
        var reassemblersByStream: [StreamID: FrameReassembler] = [:]
        var mosaicReassemblersByStream: [StreamID: StreamControllerMosaicMediaUnitReassembler] = [:]
        var mosaicPipelinesByStream: [StreamID: StreamControllerMosaicClientPipeline] = [:]
        var mosaicTilePlansByStream: [StreamID: MirageMosaicTilePlan] = [:]
        var mosaicContentRectsByStream: [StreamID: CGRect] = [:]
        var bufferedMosaicUnitsByStream: [StreamID: [StreamControllerMosaicMediaUnitReassembler.CompletedUnit]] = [:]
        var bufferedEarlyVideoPacketByStream: [StreamID: Data] = [:]
        var observedMediaStreamLabels: Set<String> = []
        var firstVideoPacketRejectionReasonByStream: [StreamID: IncomingVideoPacketRejectionReason] = [:]
        var lastInboundControlActivityTime: CFAbsoluteTime = 0
        var lastInboundMediaActivityTime: CFAbsoluteTime = 0
    }

    private let lock = NSLock()
    private var state = State()

    var activeStreamIDs: Set<StreamID> {
        withLock { $0.activeStreamIDs }
    }

    func addActiveStreamID(_ id: StreamID) {
        withLock { $0.activeStreamIDs.formUnion([id]) }
    }

    func removeActiveStreamID(_ id: StreamID) {
        withLock { $0.activeStreamIDs.subtract([id]) }
    }

    func clearActiveStreamIDs() {
        withLock { $0.activeStreamIDs.removeAll() }
    }

    func videoPacketContext(for streamID: StreamID) -> VideoPacketContext? {
        withLock { state in
            guard state.activeStreamIDs.contains(streamID) else { return nil }
            let consumedStartupPending = state.startupPacketPending.remove(streamID) != nil
            let mosaicReassembler: StreamControllerMosaicMediaUnitReassembler
            if let existingReassembler = state.mosaicReassemblersByStream[streamID] {
                mosaicReassembler = existingReassembler
            } else {
                mosaicReassembler = StreamControllerMosaicMediaUnitReassembler(streamID: streamID)
                state.mosaicReassemblersByStream[streamID] = mosaicReassembler
            }
            let mosaicPipeline: StreamControllerMosaicClientPipeline
            if let existingPipeline = state.mosaicPipelinesByStream[streamID] {
                mosaicPipeline = existingPipeline
            } else {
                mosaicPipeline = StreamControllerMosaicClientPipeline(streamID: streamID)
                state.mosaicPipelinesByStream[streamID] = mosaicPipeline
            }
            return VideoPacketContext(
                consumedStartupPending: consumedStartupPending,
                reassembler: state.reassemblersByStream[streamID],
                mosaicReassembler: mosaicReassembler,
                mosaicPipeline: mosaicPipeline,
                mosaicTilePlan: state.mosaicTilePlansByStream[streamID],
                mosaicContentRect: state.mosaicContentRectsByStream[streamID] ?? .zero,
                mediaPacketKey: state.mediaSecurityPacketKey
            )
        }
    }

    func setReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        withLock { state in
            state.reassemblersByStream = snapshot
            state.mosaicReassemblersByStream = state.mosaicReassemblersByStream.filter {
                snapshot.keys.contains($0.key)
            }
            state.mosaicPipelinesByStream = state.mosaicPipelinesByStream.filter {
                snapshot.keys.contains($0.key)
            }
            state.mosaicTilePlansByStream = state.mosaicTilePlansByStream.filter {
                snapshot.keys.contains($0.key)
            }
            state.mosaicContentRectsByStream = state.mosaicContentRectsByStream.filter {
                snapshot.keys.contains($0.key)
            }
            state.bufferedMosaicUnitsByStream = state.bufferedMosaicUnitsByStream.filter {
                snapshot.keys.contains($0.key)
            }
        }
    }

    func setMosaicTilePlan(_ plan: MirageMosaicTilePlan, for streamID: StreamID) {
        withLock { $0.mosaicTilePlansByStream[streamID] = plan }
    }

    func setMosaicContentRect(_ contentRect: CGRect, for streamID: StreamID) {
        withLock { $0.mosaicContentRectsByStream[streamID] = contentRect }
    }

    func bufferMosaicUnit(
        _ unit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        for streamID: StreamID
    ) -> Bool {
        withLock { state in
            guard state.activeStreamIDs.contains(streamID) else { return false }
            var units = state.bufferedMosaicUnitsByStream[streamID] ?? []
            guard units.count < 8 else { return false }
            units.append(unit)
            state.bufferedMosaicUnitsByStream[streamID] = units
            return true
        }
    }

    func takeBufferedMosaicUnits(for streamID: StreamID) -> [StreamControllerMosaicMediaUnitReassembler.CompletedUnit] {
        withLock { $0.bufferedMosaicUnitsByStream.removeValue(forKey: streamID) ?? [] }
    }

    func bufferedMosaicUnitCount(for streamID: StreamID) -> Int {
        withLock { $0.bufferedMosaicUnitsByStream[streamID]?.count ?? 0 }
    }

    func clearBufferedMosaicUnits(for streamID: StreamID) {
        withLock { _ = $0.bufferedMosaicUnitsByStream.removeValue(forKey: streamID) }
    }

    func bufferEarlyVideoPacket(_ data: Data, for streamID: StreamID) -> Bool {
        withLock { state in
            guard !state.activeStreamIDs.contains(streamID),
                  state.bufferedEarlyVideoPacketByStream[streamID] == nil,
                  state.bufferedEarlyVideoPacketByStream.count < 16 else {
                return false
            }
            state.bufferedEarlyVideoPacketByStream[streamID] = data
            return true
        }
    }

    func takeBufferedEarlyVideoPacket(for streamID: StreamID) -> Data? {
        withLock { $0.bufferedEarlyVideoPacketByStream.removeValue(forKey: streamID) }
    }

    func clearBufferedEarlyVideoPacket(for streamID: StreamID) {
        withLock { state in
            _ = state.bufferedEarlyVideoPacketByStream.removeValue(forKey: streamID)
        }
    }

    func clearAllBufferedEarlyVideoPackets() {
        withLock { $0.bufferedEarlyVideoPacketByStream.removeAll() }
    }

    func setMediaSecurityContext(_ context: MirageMediaSecurityContext?) {
        withLock { state in
            state.mediaSecurityPacketKey = context.map(MirageMediaPacketKey.init(context:))
        }
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
        withLock { $0.startupPacketPending.formUnion([streamID]) }
    }

    func clearStartupPacketPending(_ streamID: StreamID) {
        withLock { $0.startupPacketPending.subtract([streamID]) }
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
            state.bufferedEarlyVideoPacketByStream.removeAll()
            state.bufferedMosaicUnitsByStream.removeAll()
        }
    }

    func noteInboundControlActivity(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        withLock { $0.lastInboundControlActivityTime = now }
    }

    func noteInboundMediaActivity(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        withLock { $0.lastInboundMediaActivityTime = now }
    }

    var latestInboundActivityTime: CFAbsoluteTime {
        withLock { max($0.lastInboundControlActivityTime, $0.lastInboundMediaActivityTime) }
    }

    func resetInboundActivity(now: CFAbsoluteTime = 0) {
        withLock { state in
            state.lastInboundControlActivityTime = now
            state.lastInboundMediaActivityTime = now
        }
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
