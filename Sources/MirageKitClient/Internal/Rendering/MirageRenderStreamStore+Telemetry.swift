//
//  MirageRenderStreamStore+Telemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreMedia
import Foundation
import MirageKit

extension MirageRenderStreamStore {
    /// Records a display-clock tick for cadence and missed-vsync telemetry.
    func noteDisplayTick(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(now, samples: &state.displayTickSamples, startIndex: &state.displayTickSampleStartIndex)
        if state.lastDisplayTickTime > 0 {
            let intervalMs = max(0, now - state.lastDisplayTickTime) * 1000
            appendFrameIntervalSampleLocked(
                time: now,
                intervalMs: intervalMs,
                samples: &state.displayTickIntervalSamples,
                startIndex: &state.displayTickIntervalSampleStartIndex
            )
            let targetFrameMs = 1000 / Double(max(1, state.displayTargetFPS))
            if intervalMs > targetFrameMs * 1.5 {
                state.missedVSyncCountSinceLastSnapshot &+= 1
            }
        }
        state.lastDisplayTickTime = now
        state.lock.unlock()
    }

    /// Records that a display tick reused the previously submitted frame.
    func noteRepeatedDisplayTick(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        if state.lastSubmittedSequence > 0 {
            state.repeatedFrameCountSinceLastSnapshot &+= 1
        }
        state.lock.unlock()
    }

    /// Marks a frame sequence as submitted to the render surface.
    ///
    /// Duplicate submissions do not count as unique presentation progress.
    func markSubmitted(
        sequence: UInt64,
        remotePresentationTime: CMTime = .invalid,
        for streamID: StreamID
    ) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        guard sequence > state.lastSubmittedSequence else {
            state.lock.unlock()
            return
        }

        let previousSubmittedTime = state.lastSubmittedTime
        if previousSubmittedTime > 0 {
            let intervalMs = max(0, now - previousSubmittedTime) * 1000
            appendFrameIntervalSampleLocked(
                time: now,
                intervalMs: intervalMs,
                samples: &state.frameIntervalSamples,
                startIndex: &state.frameIntervalSampleStartIndex
            )
            if intervalMs >= Self.presentationStallThresholdMs {
                state.presentationStallCountSinceLastSnapshot &+= 1
                state.worstPresentationGapMsSinceLastSnapshot = max(
                    state.worstPresentationGapMsSinceLastSnapshot,
                    intervalMs
                )
            }
        }

        state.lastSubmittedSequence = sequence
        state.lastSubmittedGeneration = state.generation
        state.lastSubmittedTime = now
        state.lastSubmittedRemotePresentationTime = remotePresentationTime
        appendSampleLocked(
            now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        state.lock.unlock()

        if let mediaStreamID = MirageAppAtlasRenderFanout.shared.mediaStreamID(forLogicalStreamID: streamID) {
            markSubmitted(
                sequence: sequence,
                remotePresentationTime: remotePresentationTime,
                for: mediaStreamID
            )
        }
    }

    func markSubmitted(
        cursor: MirageRenderCursor,
        remotePresentationTime: CMTime = .invalid,
        mappedPresentationTime: CMTime = .invalid,
        for streamID: StreamID
    ) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        guard cursor.isAfter(MirageRenderCursor(generation: state.generation, sequence: state.lastSubmittedSequence)) ||
            state.lastSubmittedSequence == 0 else {
            state.lock.unlock()
            return
        }

        let previousSubmittedTime = state.lastSubmittedTime
        if previousSubmittedTime > 0 {
            let intervalMs = max(0, now - previousSubmittedTime) * 1000
            appendFrameIntervalSampleLocked(
                time: now,
                intervalMs: intervalMs,
                samples: &state.frameIntervalSamples,
                startIndex: &state.frameIntervalSampleStartIndex
            )
            if intervalMs >= Self.presentationStallThresholdMs {
                state.presentationStallCountSinceLastSnapshot &+= 1
                state.worstPresentationGapMsSinceLastSnapshot = max(
                    state.worstPresentationGapMsSinceLastSnapshot,
                    intervalMs
                )
            }
        }

        state.lastSubmittedSequence = cursor.sequence
        state.lastSubmittedGeneration = cursor.generation
        state.lastSubmittedTime = now
        state.lastSubmittedRemotePresentationTime = remotePresentationTime
        state.lastSubmittedMappedPresentationTime = mappedPresentationTime
        if let index = state.pendingFrames.firstIndex(where: { $0.cursor == cursor }),
           let timeline = state.pendingFrames[index].timeline {
            state.lastAcceptedFrameTimeline = timeline.markingDisplayAccepted(at: now)
        }
        if let index = state.pendingFrames.firstIndex(where: { $0.cursor == cursor }) {
            state.lastSubmittedFrameNumber = state.pendingFrames[index].frameNumber
        }
        appendSampleLocked(
            now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        state.lock.unlock()

        if let mediaStreamID = MirageAppAtlasRenderFanout.shared.mediaStreamID(forLogicalStreamID: streamID) {
            markSubmitted(
                sequence: cursor.sequence,
                remotePresentationTime: remotePresentationTime,
                for: mediaStreamID
            )
        }
    }

    /// Returns the latest unique submission state for timestamp mapping and recovery logic.
    func submissionSnapshot(for streamID: StreamID) -> SubmissionSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return SubmissionSnapshot(
                sequence: 0,
                submittedTime: 0,
                remotePresentationTime: .invalid
            )
        }

        state.lock.lock()
        let snapshot = SubmissionSnapshot(
            sequence: state.lastSubmittedSequence,
            submittedTime: state.lastSubmittedTime,
            remotePresentationTime: state.lastSubmittedRemotePresentationTime
        )
        state.lock.unlock()
        return snapshot
    }

    func renderedFrameTelemetry(for streamID: StreamID) -> MirageRenderedFrameTelemetry {
        guard let state = streamStateIfPresent(for: streamID) else {
            return MirageRenderedFrameTelemetry(
                streamID: streamID,
                selectedCursor: nil,
                selectedFrameNumber: nil,
                renderedCursor: nil,
                renderedFrameNumber: nil,
                repeatedDisplayTicks: 0,
                droppedForLatency: 0
            )
        }

        state.lock.lock()
        let renderedCursor: MirageRenderCursor? = state.lastSubmittedSequence > 0
            ? MirageRenderCursor(
                generation: state.lastSubmittedGeneration,
                sequence: state.lastSubmittedSequence
            )
            : nil
        let selectedCursor = state.pendingFrames.first { frame in
            frame.frameNumber == state.lastSelectedFrameNumber
        }?.cursor
        let telemetry = MirageRenderedFrameTelemetry(
            streamID: streamID,
            selectedCursor: selectedCursor,
            selectedFrameNumber: state.lastSelectedFrameNumber,
            renderedCursor: renderedCursor,
            renderedFrameNumber: state.lastSubmittedFrameNumber,
            repeatedDisplayTicks: state.repeatedFrameCountSinceLastSnapshot,
            droppedForLatency: state.smoothestQueueDropsSinceLastSnapshot + state.lateFrameDropsSinceLastSnapshot
        )
        state.lock.unlock()
        return telemetry
    }

    /// Records an attempted frame submission before display-layer admission.
    func noteSubmitAttempt(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        state.lock.lock()
        appendSampleLocked(now, samples: &state.submitAttemptSamples, startIndex: &state.submitAttemptSampleStartIndex)
        state.lock.unlock()
    }

    /// Records a display-layer back-pressure event.
    func noteDisplayLayerNotReady(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayLayerNotReadyCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    /// Builds and resets the rolling render telemetry counters for one stream.
    func renderTelemetrySnapshot(
        for streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RenderTelemetrySnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return RenderTelemetrySnapshot(
                displayTickFPS: 0,
                submitAttemptFPS: 0,
                layerAcceptedFPS: 0,
                presentedFPS: 0,
                submittedFPS: 0,
                uniqueSubmittedFPS: 0,
                pendingFrameCount: 0,
                pendingFrameAgeMs: 0,
                pendingFrameAgeP95Ms: 0,
                pendingFrameAgeMaxMs: 0,
                pendingFrameDepthMax: 0,
                overwrittenPendingFrames: 0,
                smoothestQueueDrops: 0,
                smoothestDepthDrops: 0,
                smoothestAgeDrops: 0,
                smoothestDropsUnder100ms: 0,
                smoothestDroppedFrameAgeMaxMs: 0,
                lateFrameDrops: 0,
                coalescedBeforeSubmitCount: 0,
                duplicateRemoteTimestampCount: 0,
                correctedStreamTimestampCount: 0,
                displayLayerNotReadyCount: 0,
                repeatedFrameCount: 0,
                displayTickNoFrameCount: 0,
                frameArrivedAfterNoFrameTickCount: 0,
                frameArrivalFallbackCount: 0,
                frameArrivalFallbackScheduledCount: 0,
                frameArrivalFallbackSubmittedCount: 0,
                noFrameTickToFrameArrivalMaxMs: 0,
                missedVSyncCount: 0,
                displayTickIntervalP95Ms: 0,
                displayTickIntervalP99Ms: 0,
                playoutDelayFrames: 0,
                presentationStallCount: 0,
                worstPresentationGapMs: 0,
                frameIntervalP95Ms: 0,
                frameIntervalP99Ms: 0,
                decodeHealthy: true
            )
        }

        state.lock.lock()
        trimSamplesLocked(now: now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.displayTickSamples,
            startIndex: &state.displayTickSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.submitAttemptSamples,
            startIndex: &state.submitAttemptSampleStartIndex
        )
        trimSamplesLocked(now: now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.frameIntervalSamples,
            startIndex: &state.frameIntervalSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.displayTickIntervalSamples,
            startIndex: &state.displayTickIntervalSampleStartIndex
        )
        trimMetricSamplesLocked(
            now: now,
            samples: &state.pendingFrameAgeSamples,
            startIndex: &state.pendingFrameAgeSampleStartIndex
        )
        trimMetricSamplesLocked(
            now: now,
            samples: &state.pendingFrameDepthSamples,
            startIndex: &state.pendingFrameDepthSampleStartIndex
        )

        let decodeFPS = Double(state.decodeSamples.count - state.decodeSampleStartIndex)
        let displayTickFPS = Double(state.displayTickSamples.count - state.displayTickSampleStartIndex)
        let submitAttemptFPS = Double(state.submitAttemptSamples.count - state.submitAttemptSampleStartIndex)
        let submittedFPS = Double(state.submittedSamples.count - state.submittedSampleStartIndex)
        let uniqueSubmittedFPS = Double(state.uniqueSubmittedSamples.count - state.uniqueSubmittedSampleStartIndex)
        let pendingFrameCount = state.pendingFrames.count
        let pendingFrameAgeMs = pendingFrameAgeMsLocked(state: state, now: now)
        let pendingFrameAgeValues = Array(
            state.pendingFrameAgeSamples[state.pendingFrameAgeSampleStartIndex...].map(\.value)
        )
        let pendingFrameAgeP95Ms = percentile(pendingFrameAgeValues, percentile: 0.95)
        let pendingFrameAgeMaxMs = pendingFrameAgeValues.max() ?? pendingFrameAgeMs
        let pendingFrameDepthValues = Array(
            state.pendingFrameDepthSamples[state.pendingFrameDepthSampleStartIndex...].map(\.value)
        )
        let pendingFrameDepthMax = Int((pendingFrameDepthValues.max() ?? Double(pendingFrameCount)).rounded())
        let overwrittenPendingFrames = state.overwrittenPendingFramesSinceLastSnapshot
        let smoothestQueueDrops = state.smoothestQueueDropsSinceLastSnapshot
        let smoothestDepthDrops = state.smoothestDepthDropsSinceLastSnapshot
        let smoothestAgeDrops = state.smoothestAgeDropsSinceLastSnapshot
        let smoothestDropsUnder100ms = state.smoothestDropsUnder100msSinceLastSnapshot
        let smoothestDroppedFrameAgeMaxMs = state.smoothestDroppedFrameAgeMaxMsSinceLastSnapshot
        let lateFrameDrops = state.lateFrameDropsSinceLastSnapshot
        let coalescedBeforeSubmitCount = state.coalescedFramesSinceLastSnapshot
        let duplicateRemoteTimestampCount = state.duplicateRemoteTimestampsSinceLastSnapshot
        let correctedStreamTimestampCount = state.correctedStreamTimestampsSinceLastSnapshot
        let displayLayerNotReadyCount = state.displayLayerNotReadyCountSinceLastSnapshot
        let repeatedFrameCount = state.repeatedFrameCountSinceLastSnapshot
        let displayTickNoFrameCount = state.displayTickNoFrameCountSinceLastSnapshot
        let frameArrivedAfterNoFrameTickCount = state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot
        let frameArrivalFallbackCount = state.frameArrivalFallbackCountSinceLastSnapshot
        let frameArrivalFallbackScheduledCount = state.frameArrivalFallbackScheduledCountSinceLastSnapshot
        let frameArrivalFallbackSubmittedCount = state.frameArrivalFallbackSubmittedCountSinceLastSnapshot
        let noFrameTickToFrameArrivalMaxMs = state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot
        let missedVSyncCount = state.missedVSyncCountSinceLastSnapshot
        let presentationStallCount = state.presentationStallCountSinceLastSnapshot
        let worstPresentationGapMs = state.worstPresentationGapMsSinceLastSnapshot
        let intervalSamples = Array(state.frameIntervalSamples[state.frameIntervalSampleStartIndex...].map(\.intervalMs))
        let frameIntervalP95Ms = percentile(intervalSamples, percentile: 0.95)
        let frameIntervalP99Ms = percentile(intervalSamples, percentile: 0.99)
        let displayTickIntervalSamples = Array(
            state.displayTickIntervalSamples[state.displayTickIntervalSampleStartIndex...].map(\.intervalMs)
        )
        let displayTickIntervalP95Ms = percentile(displayTickIntervalSamples, percentile: 0.95)
        let displayTickIntervalP99Ms = percentile(displayTickIntervalSamples, percentile: 0.99)
        let playoutDelayFrames = state.playoutDelayFrames
        state.overwrittenPendingFramesSinceLastSnapshot = 0
        state.smoothestQueueDropsSinceLastSnapshot = 0
        state.smoothestDepthDropsSinceLastSnapshot = 0
        state.smoothestAgeDropsSinceLastSnapshot = 0
        state.smoothestDropsUnder100msSinceLastSnapshot = 0
        state.smoothestDroppedFrameAgeMaxMsSinceLastSnapshot = 0
        state.lateFrameDropsSinceLastSnapshot = 0
        state.coalescedFramesSinceLastSnapshot = 0
        state.duplicateRemoteTimestampsSinceLastSnapshot = 0
        state.correctedStreamTimestampsSinceLastSnapshot = 0
        state.displayLayerNotReadyCountSinceLastSnapshot = 0
        state.repeatedFrameCountSinceLastSnapshot = 0
        state.displayTickNoFrameCountSinceLastSnapshot = 0
        state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot = 0
        state.frameArrivalFallbackCountSinceLastSnapshot = 0
        state.frameArrivalFallbackScheduledCountSinceLastSnapshot = 0
        state.frameArrivalFallbackSubmittedCountSinceLastSnapshot = 0
        state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = 0
        state.missedVSyncCountSinceLastSnapshot = 0
        state.presentationStallCountSinceLastSnapshot = 0
        state.worstPresentationGapMsSinceLastSnapshot = 0

        let sourceTargetFPS = max(1, state.sourceTargetFPS)
        let decodeRatio = decodeFPS / Double(sourceTargetFPS)
        let decodeHealthy = decodeRatio >= MirageRenderModePolicy.healthyDecodeRatio
        state.lock.unlock()

        return RenderTelemetrySnapshot(
            displayTickFPS: displayTickFPS,
            submitAttemptFPS: submitAttemptFPS,
            layerAcceptedFPS: submittedFPS,
            presentedFPS: uniqueSubmittedFPS,
            submittedFPS: submittedFPS,
            uniqueSubmittedFPS: uniqueSubmittedFPS,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: pendingFrameAgeMs,
            pendingFrameAgeP95Ms: pendingFrameAgeP95Ms,
            pendingFrameAgeMaxMs: pendingFrameAgeMaxMs,
            pendingFrameDepthMax: pendingFrameDepthMax,
            overwrittenPendingFrames: overwrittenPendingFrames,
            smoothestQueueDrops: smoothestQueueDrops,
            smoothestDepthDrops: smoothestDepthDrops,
            smoothestAgeDrops: smoothestAgeDrops,
            smoothestDropsUnder100ms: smoothestDropsUnder100ms,
            smoothestDroppedFrameAgeMaxMs: smoothestDroppedFrameAgeMaxMs,
            lateFrameDrops: lateFrameDrops,
            coalescedBeforeSubmitCount: coalescedBeforeSubmitCount,
            duplicateRemoteTimestampCount: duplicateRemoteTimestampCount,
            correctedStreamTimestampCount: correctedStreamTimestampCount,
            displayLayerNotReadyCount: displayLayerNotReadyCount,
            repeatedFrameCount: repeatedFrameCount,
            displayTickNoFrameCount: displayTickNoFrameCount,
            frameArrivedAfterNoFrameTickCount: frameArrivedAfterNoFrameTickCount,
            frameArrivalFallbackCount: frameArrivalFallbackCount,
            frameArrivalFallbackScheduledCount: frameArrivalFallbackScheduledCount,
            frameArrivalFallbackSubmittedCount: frameArrivalFallbackSubmittedCount,
            noFrameTickToFrameArrivalMaxMs: noFrameTickToFrameArrivalMaxMs,
            missedVSyncCount: missedVSyncCount,
            displayTickIntervalP95Ms: displayTickIntervalP95Ms,
            displayTickIntervalP99Ms: displayTickIntervalP99Ms,
            playoutDelayFrames: playoutDelayFrames,
            presentationStallCount: presentationStallCount,
            worstPresentationGapMs: worstPresentationGapMs,
            frameIntervalP95Ms: frameIntervalP95Ms,
            frameIntervalP99Ms: frameIntervalP99Ms,
            decodeHealthy: decodeHealthy
        )
    }

    func noteDisplayTickWithoutFrame(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayTickNoFrameCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteFrameArrivedAfterNoFrameTick(for streamID: StreamID, delayMs: Double) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot &+= 1
        state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = max(
            state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot,
            delayMs
        )
        state.lock.unlock()
    }

    func noteFrameArrivalFallback(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivalFallbackCountSinceLastSnapshot &+= 1
        state.frameArrivalFallbackScheduledCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteFrameArrivalFallbackSubmitted(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivalFallbackSubmittedCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func pendingFrameAgeMs(for streamID: StreamID) -> Double {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        let now = CFAbsoluteTimeGetCurrent()
        state.lock.lock()
        let ageMs = pendingFrameAgeMsLocked(state: state, now: now)
        state.lock.unlock()
        return ageMs
    }

    func appendSampleLocked(
        _ now: CFAbsoluteTime,
        samples: inout [CFAbsoluteTime],
        startIndex: inout Int
    ) {
        samples.append(now)
        trimSamplesLocked(now: now, samples: &samples, startIndex: &startIndex)
    }

    func recordPendingQueueSampleLocked(state: MirageRenderStreamState, now: CFAbsoluteTime) {
        appendMetricSampleLocked(
            time: now,
            value: pendingFrameAgeMsLocked(state: state, now: now),
            samples: &state.pendingFrameAgeSamples,
            startIndex: &state.pendingFrameAgeSampleStartIndex
        )
        appendMetricSampleLocked(
            time: now,
            value: Double(state.pendingFrames.count),
            samples: &state.pendingFrameDepthSamples,
            startIndex: &state.pendingFrameDepthSampleStartIndex
        )
    }

    private func trimSamplesLocked(
        now: CFAbsoluteTime,
        samples: inout [CFAbsoluteTime],
        startIndex: inout Int
    ) {
        let cutoff = now - Self.sampleWindowSeconds
        while startIndex < samples.count, samples[startIndex] < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func appendFrameIntervalSampleLocked(
        time: CFAbsoluteTime,
        intervalMs: Double,
        samples: inout [(time: CFAbsoluteTime, intervalMs: Double)],
        startIndex: inout Int
    ) {
        samples.append((time: time, intervalMs: intervalMs))
        trimFrameIntervalSamplesLocked(now: time, samples: &samples, startIndex: &startIndex)
    }

    private func appendMetricSampleLocked(
        time: CFAbsoluteTime,
        value: Double,
        samples: inout [(time: CFAbsoluteTime, value: Double)],
        startIndex: inout Int
    ) {
        samples.append((time: time, value: value))
        trimMetricSamplesLocked(now: time, samples: &samples, startIndex: &startIndex)
    }

    private func trimMetricSamplesLocked(
        now: CFAbsoluteTime,
        samples: inout [(time: CFAbsoluteTime, value: Double)],
        startIndex: inout Int
    ) {
        let cutoff = now - Self.sampleWindowSeconds
        while startIndex < samples.count, samples[startIndex].time < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func trimFrameIntervalSamplesLocked(
        now: CFAbsoluteTime,
        samples: inout [(time: CFAbsoluteTime, intervalMs: Double)],
        startIndex: inout Int
    ) {
        let cutoff = now - Self.smoothnessWindowSeconds
        while startIndex < samples.count, samples[startIndex].time < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    func pendingFrameAgeMsLocked(state: MirageRenderStreamState, now: CFAbsoluteTime) -> Double {
        guard let decodeTime = state.pendingFrames.first?.decodeTime else { return 0 }
        return max(0, now - decodeTime) * 1000
    }
}
