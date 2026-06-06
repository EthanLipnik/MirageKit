//
//  MirageInputLatencyTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/16/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

package enum MirageInputLatencyEventClass: String, Sendable, CaseIterable {
    case pointer
    case scroll
    case keyboard
    case touch
    case resize
    case focus
    case other
}

package enum MirageInputLatencyClientRoute: String, Sendable, CaseIterable {
    case reliable
    case orderedBestEffort
    case priorityProtected
    case priorityRealtimeLatest
    case priorityRealtimeSequenced
    case priorityContinuousBatch
    case priorityFallback
}

package extension MirageInput.MirageInputEvent {
    var latencyEventClass: MirageInputLatencyEventClass {
        switch self {
        case .mouseMoved,
             .mouseDragged,
             .mouseDown,
             .mouseUp,
             .rightMouseDragged,
             .rightMouseDown,
             .rightMouseUp,
             .otherMouseDragged,
             .otherMouseDown,
             .otherMouseUp:
            .pointer
        case .scrollWheel,
             .magnify,
             .rotate,
             .swipe:
            .scroll
        case .keyDown,
             .keyUp,
             .flagsChanged:
            .keyboard
        case .pointerSampleBatch:
            .touch
        case .windowResize,
             .relativeResize,
             .pixelResize:
            .resize
        case .windowFocus:
            .focus
        case .hostSystemAction:
            .other
        }
    }
}

package final class MirageInputLatencyTelemetry: @unchecked Sendable {
    package static let shared = MirageInputLatencyTelemetry()

    private struct SampleWindow {
        var values: [Double] = []

        mutating func record(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            values.append(value)
            if values.count > 256 {
                values.removeFirst(values.count - 256)
            }
        }

        mutating func reset() {
            values.removeAll(keepingCapacity: true)
        }

        var p99: Double {
            percentile(0.99)
        }

        var p95: Double {
            percentile(0.95)
        }

        var max: Double {
            values.max() ?? 0
        }

        private func percentile(_ percentile: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let clamped = Swift.max(0, Swift.min(1, percentile))
            let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
            return sorted[Swift.min(Swift.max(0, index), sorted.count - 1)]
        }
    }

    private struct ClassStats {
        var lastClientSourceTimestampByName: [String: TimeInterval] = [:]
        var clientSourceGapMs = SampleWindow()
        var clientSourceToForwardMs = SampleWindow()
        var clientSourceToSuppressMs = SampleWindow()
        var clientSourceCounts: [String: UInt64] = [:]
        var clientSuppressionCounts: [String: UInt64] = [:]
        var clientBatchFlushCounts: [String: UInt64] = [:]
        var clientBatchSampleCount = SampleWindow()
        var clientBatchOldestAgeMs = SampleWindow()
        var clientBatchNewestAgeMs = SampleWindow()
        var clientBatchTimerDelayMs = SampleWindow()
        var clientPrioritySendCompletionMs = SampleWindow()
        var clientPrioritySendCompletionErrors: UInt64 = 0

        var lastClientCaptureTimestamp: TimeInterval = 0
        var clientCaptureGapMs = SampleWindow()
        var lastClientSendTimestamp: TimeInterval = 0
        var clientSendGapMs = SampleWindow()
        var clientCaptureToSendMs = SampleWindow()
        var clientRouteCounts: [MirageInputLatencyClientRoute: UInt64] = [:]
        var priorityAckAgeMs = SampleWindow()
        var lastPriorityRouteState: String?
        var clientFallbackCount: UInt64 = 0

        var lastHostReceiveTimestamp: TimeInterval = 0
        var hostReceiveGapMs = SampleWindow()
        var hostSchedulerDepthMax = 0
        var hostSchedulerDwellMs = SampleWindow()
        var hostSchedulerDispatchAgeMs = SampleWindow()
        var hostAccessibilityDwellMs = SampleWindow()
        var hostCursorWarpMs = SampleWindow()
        var hostInjectionDurationMs = SampleWindow()
        var hostInjectionAgeMs = SampleWindow()
        var hostBatchSampleCount = SampleWindow()
        var hostBatchOldestAgeMs = SampleWindow()
        var hostBatchNewestAgeMs = SampleWindow()

        var hasClientSamples: Bool {
            !clientSourceGapMs.values.isEmpty ||
                !clientSourceToForwardMs.values.isEmpty ||
                !clientSourceToSuppressMs.values.isEmpty ||
                !clientSourceCounts.isEmpty ||
                !clientSuppressionCounts.isEmpty ||
                !clientBatchFlushCounts.isEmpty ||
                !clientBatchSampleCount.values.isEmpty ||
                !clientBatchOldestAgeMs.values.isEmpty ||
                !clientBatchNewestAgeMs.values.isEmpty ||
                !clientBatchTimerDelayMs.values.isEmpty ||
                !clientPrioritySendCompletionMs.values.isEmpty ||
                clientPrioritySendCompletionErrors > 0 ||
                !clientCaptureGapMs.values.isEmpty ||
                !clientSendGapMs.values.isEmpty ||
                !clientCaptureToSendMs.values.isEmpty ||
                !clientRouteCounts.isEmpty ||
                !priorityAckAgeMs.values.isEmpty ||
                clientFallbackCount > 0
        }

        var hasHostSamples: Bool {
            !hostReceiveGapMs.values.isEmpty ||
                !hostSchedulerDwellMs.values.isEmpty ||
                !hostSchedulerDispatchAgeMs.values.isEmpty ||
                !hostAccessibilityDwellMs.values.isEmpty ||
                !hostCursorWarpMs.values.isEmpty ||
                !hostInjectionDurationMs.values.isEmpty ||
                !hostInjectionAgeMs.values.isEmpty ||
                !hostBatchSampleCount.values.isEmpty ||
                !hostBatchOldestAgeMs.values.isEmpty ||
                !hostBatchNewestAgeMs.values.isEmpty ||
                hostSchedulerDepthMax > 0
        }

        var hasClientSourceDiagnostics: Bool {
            !clientSourceGapMs.values.isEmpty ||
                !clientSourceToForwardMs.values.isEmpty ||
                !clientSourceToSuppressMs.values.isEmpty ||
                !clientSourceCounts.isEmpty ||
                !clientSuppressionCounts.isEmpty
        }

        var hasClientBatchDiagnostics: Bool {
            !clientBatchFlushCounts.isEmpty ||
                !clientBatchSampleCount.values.isEmpty ||
                !clientBatchOldestAgeMs.values.isEmpty ||
                !clientBatchNewestAgeMs.values.isEmpty ||
                !clientBatchTimerDelayMs.values.isEmpty
        }

        var hasClientPriorityCompletionDiagnostics: Bool {
            !clientPrioritySendCompletionMs.values.isEmpty ||
                clientPrioritySendCompletionErrors > 0
        }

        var hasHostBatchDiagnostics: Bool {
            !hostBatchSampleCount.values.isEmpty ||
                !hostBatchOldestAgeMs.values.isEmpty ||
                !hostBatchNewestAgeMs.values.isEmpty
        }

        mutating func resetClientWindow() {
            clientSourceGapMs.reset()
            clientSourceToForwardMs.reset()
            clientSourceToSuppressMs.reset()
            clientSourceCounts.removeAll(keepingCapacity: true)
            clientSuppressionCounts.removeAll(keepingCapacity: true)
            clientBatchFlushCounts.removeAll(keepingCapacity: true)
            clientBatchSampleCount.reset()
            clientBatchOldestAgeMs.reset()
            clientBatchNewestAgeMs.reset()
            clientBatchTimerDelayMs.reset()
            clientPrioritySendCompletionMs.reset()
            clientPrioritySendCompletionErrors = 0
            clientCaptureGapMs.reset()
            clientSendGapMs.reset()
            clientCaptureToSendMs.reset()
            clientRouteCounts.removeAll(keepingCapacity: true)
            priorityAckAgeMs.reset()
            clientFallbackCount = 0
        }

        mutating func resetHostWindow() {
            hostReceiveGapMs.reset()
            hostSchedulerDwellMs.reset()
            hostSchedulerDispatchAgeMs.reset()
            hostAccessibilityDwellMs.reset()
            hostCursorWarpMs.reset()
            hostInjectionDurationMs.reset()
            hostInjectionAgeMs.reset()
            hostBatchSampleCount.reset()
            hostBatchOldestAgeMs.reset()
            hostBatchNewestAgeMs.reset()
            hostSchedulerDepthMax = 0
        }
    }

    private let lock = NSLock()
    private var statsByClass: [MirageInputLatencyEventClass: ClassStats] = [:]
    private var lastClientLogTime: TimeInterval = 0
    private var lastHostLogTime: TimeInterval = 0
    private let logIntervalSeconds: TimeInterval = 2.0

    private init() {}

    package func recordClientSource(
        eventClass: MirageInputLatencyEventClass,
        streamID: StreamID?,
        source: String,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        var stats = statsByClass[eventClass] ?? ClassStats()
        if let previousTimestamp = stats.lastClientSourceTimestampByName[source], previousTimestamp > 0 {
            stats.clientSourceGapMs.record(max(0, timestamp - previousTimestamp) * 1000)
        }
        stats.lastClientSourceTimestampByName[source] = timestamp
        stats.clientSourceCounts[source, default: 0] &+= 1
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientSourceForward(
        event: MirageInput.MirageInputEvent,
        streamID: StreamID?,
        source: String,
        sourceTimestamp: TimeInterval,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        let eventClass = event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientSourceToForwardMs.record(max(0, now - sourceTimestamp) * 1000)
        stats.clientSourceCounts["\(source).forwarded", default: 0] &+= 1
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientSourceSuppression(
        eventClass: MirageInputLatencyEventClass,
        streamID: StreamID?,
        source: String,
        reason: String,
        sourceTimestamp: TimeInterval,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientSourceToSuppressMs.record(max(0, now - sourceTimestamp) * 1000)
        stats.clientSuppressionCounts["\(source).\(reason)", default: 0] &+= 1
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientContinuousBatchFlush(
        _ batch: MirageInput.MirageContinuousInputBatch,
        reason: String,
        scheduledAt: TimeInterval? = nil,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        lock.lock()
        let eventClass = Self.eventClass(for: batch)
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientBatchFlushCounts[reason, default: 0] &+= 1
        stats.clientBatchSampleCount.record(Double(batch.samples.count))
        if let oldest = batch.samples.first?.timestamp {
            stats.clientBatchOldestAgeMs.record(max(0, now - oldest) * 1000)
        }
        if let newest = batch.samples.last?.timestamp {
            stats.clientBatchNewestAgeMs.record(max(0, now - newest) * 1000)
        }
        if let scheduledAt {
            stats.clientBatchTimerDelayMs.record(max(0, now - scheduledAt) * 1000)
        }
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientPrioritySendCompletion(
        envelope: MirageWire.MiragePriorityInputEnvelope,
        durationMs: Double,
        error: Error?,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let eventClass = Self.eventClass(for: envelope) else {
            return
        }
        lock.lock()
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientPrioritySendCompletionMs.record(durationMs)
        if error != nil {
            stats.clientPrioritySendCompletionErrors &+= 1
        }
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientCapture(
        event: MirageInput.MirageInputEvent,
        streamID: StreamID,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        let eventClass = event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        if stats.lastClientCaptureTimestamp > 0 {
            stats.clientCaptureGapMs.record(max(0, event.timestamp - stats.lastClientCaptureTimestamp) * 1000)
        }
        stats.lastClientCaptureTimestamp = event.timestamp
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientSend(
        event: MirageInput.MirageInputEvent,
        streamID: StreamID,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        let eventClass = event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        if stats.lastClientSendTimestamp > 0 {
            stats.clientSendGapMs.record(max(0, now - stats.lastClientSendTimestamp) * 1000)
        }
        stats.clientCaptureToSendMs.record(max(0, now - event.timestamp) * 1000)
        stats.lastClientSendTimestamp = now
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientRoute(
        event: MirageInput.MirageInputEvent,
        streamID: StreamID,
        route: MirageInputLatencyClientRoute,
        priorityRouteState: String? = nil,
        priorityAckAgeMs: Double? = nil,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        let eventClass = event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientRouteCounts[route, default: 0] &+= 1
        if let priorityRouteState {
            stats.lastPriorityRouteState = priorityRouteState
        }
        if let priorityAckAgeMs {
            stats.priorityAckAgeMs.record(priorityAckAgeMs)
        }
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientFallback(
        event: MirageInput.MirageInputEvent,
        streamID: StreamID,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        _ = streamID
        lock.lock()
        let eventClass = event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.clientFallbackCount &+= 1
        statsByClass[eventClass] = stats
        logClientIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordClientFallback(
        envelope: MirageWire.MiragePriorityInputEnvelope,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        if envelope.kind == .continuousInput,
           let batch = try? MirageInput.MirageContinuousInputBatch.deserialize(envelope.inputPayload) {
            for event in batch.inputEvents() {
                recordClientFallback(event: event, streamID: batch.streamID, now: now)
            }
            return
        }
        guard let inputMessage = try? MirageWire.InputEventMessage.deserializePayload(envelope.inputPayload) else { return }
        recordClientFallback(event: inputMessage.event, streamID: inputMessage.streamID, now: now)
    }

    package func recordHostReceive(
        message: MirageWire.ControlMessage,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? MirageWire.InputEventMessage.deserializePayload(message.payload) else {
            return
        }
        lock.lock()
        let eventClass = inputMessage.event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        if stats.lastHostReceiveTimestamp > 0 {
            stats.hostReceiveGapMs.record(max(0, now - stats.lastHostReceiveTimestamp) * 1000)
        }
        stats.lastHostReceiveTimestamp = now
        statsByClass[eventClass] = stats
        logHostIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordHostContinuousBatchReceive(
        _ batch: MirageInput.MirageContinuousInputBatch,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        lock.lock()
        let eventClass = Self.eventClass(for: batch)
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.hostBatchSampleCount.record(Double(batch.samples.count))
        if let oldest = batch.samples.first?.timestamp {
            stats.hostBatchOldestAgeMs.record(max(0, now - oldest) * 1000)
        }
        if let newest = batch.samples.last?.timestamp {
            stats.hostBatchNewestAgeMs.record(max(0, now - newest) * 1000)
        }
        statsByClass[eventClass] = stats
        logHostIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordHostSchedulerDepth(
        message: MirageWire.ControlMessage,
        depth: Int,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? MirageWire.InputEventMessage.deserializePayload(message.payload) else {
            return
        }
        lock.lock()
        let eventClass = inputMessage.event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.hostSchedulerDepthMax = max(stats.hostSchedulerDepthMax, max(0, depth))
        statsByClass[eventClass] = stats
        logHostIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordHostPost(
        message: MirageWire.ControlMessage,
        enqueuedAt: TimeInterval,
        schedulerDepth: Int,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? MirageWire.InputEventMessage.deserializePayload(message.payload) else {
            return
        }
        lock.lock()
        let eventClass = inputMessage.event.latencyEventClass
        var stats = statsByClass[eventClass] ?? ClassStats()
        stats.hostSchedulerDepthMax = max(stats.hostSchedulerDepthMax, max(0, schedulerDepth))
        stats.hostSchedulerDwellMs.record(max(0, now - enqueuedAt) * 1000)
        stats.hostSchedulerDispatchAgeMs.record(max(0, now - inputMessage.event.timestamp) * 1000)
        statsByClass[eventClass] = stats
        logHostIfNeededLocked(now: now)
        lock.unlock()
    }

    package func recordHostAccessibilityDwell(
        event: MirageInput.MirageInputEvent,
        enqueuedAt: TimeInterval,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        recordHostStage(
            eventClass: event.latencyEventClass,
            now: now
        ) { stats in
            stats.hostAccessibilityDwellMs.record(max(0, now - enqueuedAt) * 1000)
        }
    }

    package func recordHostCursorWarp(
        eventClass: MirageInputLatencyEventClass,
        durationMs: Double,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        recordHostStage(eventClass: eventClass, now: now) { stats in
            stats.hostCursorWarpMs.record(durationMs)
        }
    }

    package func recordHostInjection(
        eventClass: MirageInputLatencyEventClass,
        eventTimestamp: TimeInterval,
        durationMs: Double,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        recordHostStage(eventClass: eventClass, now: now) { stats in
            stats.hostInjectionDurationMs.record(durationMs)
            stats.hostInjectionAgeMs.record(max(0, now - eventTimestamp) * 1000)
        }
    }

    private func recordHostStage(
        eventClass: MirageInputLatencyEventClass,
        now: TimeInterval,
        update: (inout ClassStats) -> Void
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled() else { return }
        lock.lock()
        var stats = statsByClass[eventClass] ?? ClassStats()
        update(&stats)
        statsByClass[eventClass] = stats
        logHostIfNeededLocked(now: now)
        lock.unlock()
    }

    private func logClientIfNeededLocked(now: TimeInterval) {
        guard lastClientLogTime == 0 || now - lastClientLogTime >= logIntervalSeconds else { return }
        let fragments = MirageInputLatencyEventClass.allCases.compactMap { eventClass -> String? in
            guard let stats = statsByClass[eventClass], stats.hasClientSamples else { return nil }
            let routes = formattedRoutes(stats.clientRouteCounts)
            let routeState = stats.lastPriorityRouteState ?? "--"
            var fragment = "\(eventClass.rawValue):captureGapP99=\(formatMs(stats.clientCaptureGapMs.p99))ms " +
                "sendGapP99=\(formatMs(stats.clientSendGapMs.p99))ms " +
                "sendGapMax=\(formatMs(stats.clientSendGapMs.max))ms " +
                "captureToSendP99=\(formatMs(stats.clientCaptureToSendMs.p99))ms " +
                "captureToSendMax=\(formatMs(stats.clientCaptureToSendMs.max))ms " +
                "routes=\(routes) priorityState=\(routeState) " +
                "priorityAckAgeP99=\(formatMs(stats.priorityAckAgeMs.p99))ms " +
                "priorityAckAgeMax=\(formatMs(stats.priorityAckAgeMs.max))ms " +
                "fallbacks=\(stats.clientFallbackCount)"
            if stats.hasClientSourceDiagnostics {
                fragment += " sourceGapP99=\(formatMs(stats.clientSourceGapMs.p99))ms " +
                    "sourceToForwardP99=\(formatMs(stats.clientSourceToForwardMs.p99))ms " +
                    "sourceToSuppressP99=\(formatMs(stats.clientSourceToSuppressMs.p99))ms " +
                    "sources=\(formattedCounts(stats.clientSourceCounts)) " +
                    "suppressions=\(formattedCounts(stats.clientSuppressionCounts))"
            }
            if stats.hasClientBatchDiagnostics {
                fragment += " batchFlushes=\(formattedCounts(stats.clientBatchFlushCounts)) " +
                    "batchSamplesP99=\(formatCount(stats.clientBatchSampleCount.p99)) " +
                    "batchOldestAgeP99=\(formatMs(stats.clientBatchOldestAgeMs.p99))ms " +
                    "batchNewestAgeP99=\(formatMs(stats.clientBatchNewestAgeMs.p99))ms " +
                    "batchTimerDelayP99=\(formatMs(stats.clientBatchTimerDelayMs.p99))ms"
            }
            if stats.hasClientPriorityCompletionDiagnostics {
                fragment += " priorityContentProcessedP99=\(formatMs(stats.clientPrioritySendCompletionMs.p99))ms " +
                    "priorityContentProcessedMax=\(formatMs(stats.clientPrioritySendCompletionMs.max))ms " +
                    "priorityContentProcessedErrors=\(stats.clientPrioritySendCompletionErrors)"
            }
            return fragment
        }
        guard !fragments.isEmpty else { return }
        MirageLogger.client("Input latency diagnostics client \(fragments.joined(separator: " | "))")
        lastClientLogTime = now
        resetClientWindowsLocked()
    }

    private func logHostIfNeededLocked(now: TimeInterval) {
        guard lastHostLogTime == 0 || now - lastHostLogTime >= logIntervalSeconds else { return }
        let fragments = MirageInputLatencyEventClass.allCases.compactMap { eventClass -> String? in
            guard let stats = statsByClass[eventClass], stats.hasHostSamples else { return nil }
            var fragment = "\(eventClass.rawValue):receiveGapP99=\(formatMs(stats.hostReceiveGapMs.p99))ms " +
                "schedulerDepth=\(stats.hostSchedulerDepthMax) " +
                "schedulerDwellP99=\(formatMs(stats.hostSchedulerDwellMs.p99))ms " +
                "dispatchAgeP99=\(formatMs(stats.hostSchedulerDispatchAgeMs.p99))ms " +
                "dispatchAgeMax=\(formatMs(stats.hostSchedulerDispatchAgeMs.max))ms " +
                "accessDwellP99=\(formatMs(stats.hostAccessibilityDwellMs.p99))ms " +
                "accessDwellMax=\(formatMs(stats.hostAccessibilityDwellMs.max))ms " +
                "warpP99=\(formatMs(stats.hostCursorWarpMs.p99))ms " +
                "warpMax=\(formatMs(stats.hostCursorWarpMs.max))ms " +
                "injectP99=\(formatMs(stats.hostInjectionDurationMs.p99))ms " +
                "injectMax=\(formatMs(stats.hostInjectionDurationMs.max))ms " +
                "injectAgeP99=\(formatMs(stats.hostInjectionAgeMs.p99))ms " +
                "injectAgeMax=\(formatMs(stats.hostInjectionAgeMs.max))ms"
            if stats.hasHostBatchDiagnostics {
                fragment += " hostBatchSamplesP99=\(formatCount(stats.hostBatchSampleCount.p99)) " +
                    "hostBatchOldestAgeP99=\(formatMs(stats.hostBatchOldestAgeMs.p99))ms " +
                    "hostBatchNewestAgeP99=\(formatMs(stats.hostBatchNewestAgeMs.p99))ms"
            }
            return fragment
        }
        guard !fragments.isEmpty else { return }
        MirageLogger.host("Input latency diagnostics host \(fragments.joined(separator: " | "))")
        lastHostLogTime = now
        resetHostWindowsLocked()
    }

    private func resetClientWindowsLocked() {
        for key in Array(statsByClass.keys) {
            guard var stats = statsByClass[key] else { continue }
            stats.resetClientWindow()
            statsByClass[key] = stats
        }
    }

    private func resetHostWindowsLocked() {
        for key in Array(statsByClass.keys) {
            guard var stats = statsByClass[key] else { continue }
            stats.resetHostWindow()
            statsByClass[key] = stats
        }
    }

    private func formatMs(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func formattedRoutes(_ counts: [MirageInputLatencyClientRoute: UInt64]) -> String {
        let fragments = MirageInputLatencyClientRoute.allCases.compactMap { route -> String? in
            guard let count = counts[route], count > 0 else { return nil }
            return "\(route.rawValue)=\(count)"
        }
        return fragments.isEmpty ? "--" : fragments.joined(separator: ",")
    }

    private func formatCount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func formattedCounts(_ counts: [String: UInt64]) -> String {
        let fragments = counts
            .filter { $0.value > 0 }
            .sorted { left, right in
                if left.key == right.key { return left.value > right.value }
                return left.key < right.key
            }
            .map { "\($0.key)=\($0.value)" }
        return fragments.isEmpty ? "--" : fragments.joined(separator: ",")
    }

    private static func eventClass(for batch: MirageInput.MirageContinuousInputBatch) -> MirageInputLatencyEventClass {
        switch batch.kind {
        case .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            .pointer
        case .pointerSampleBatch:
            .touch
        case .scroll,
             .magnify,
             .rotate,
             .swipe:
            .scroll
        }
    }

    private static func eventClass(for envelope: MirageWire.MiragePriorityInputEnvelope) -> MirageInputLatencyEventClass? {
        if envelope.kind == .continuousInput,
           let batch = try? MirageInput.MirageContinuousInputBatch.deserialize(envelope.inputPayload) {
            return eventClass(for: batch)
        }
        guard let inputMessage = try? MirageWire.InputEventMessage.deserializePayload(envelope.inputPayload) else {
            return nil
        }
        return inputMessage.event.latencyEventClass
    }
}
