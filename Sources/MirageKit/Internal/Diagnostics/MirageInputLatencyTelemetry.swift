//
//  MirageInputLatencyTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/16/26.
//

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
    case priorityFallback
}

package extension MirageInputEvent {
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

        var hasClientSamples: Bool {
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
                hostSchedulerDepthMax > 0
        }

        mutating func resetClientWindow() {
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
            hostSchedulerDepthMax = 0
        }
    }

    private let lock = NSLock()
    private var statsByClass: [MirageInputLatencyEventClass: ClassStats] = [:]
    private var lastClientLogTime: TimeInterval = 0
    private var lastHostLogTime: TimeInterval = 0
    private let logIntervalSeconds: TimeInterval = 2.0

    private init() {}

    package func recordClientCapture(
        event: MirageInputEvent,
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
        event: MirageInputEvent,
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
        event: MirageInputEvent,
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
        event: MirageInputEvent,
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
        envelope: MiragePriorityInputEnvelope,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard let inputMessage = try? InputEventMessage.deserializePayload(envelope.inputPayload) else { return }
        recordClientFallback(event: inputMessage.event, streamID: inputMessage.streamID, now: now)
    }

    package func recordHostReceive(
        message: ControlMessage,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else {
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

    package func recordHostSchedulerDepth(
        message: ControlMessage,
        depth: Int,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else {
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
        message: ControlMessage,
        enqueuedAt: TimeInterval,
        schedulerDepth: Int,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard MirageLatencyOptions.latencyDiagnosticsEnabled(),
              let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else {
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
        event: MirageInputEvent,
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
            return "\(eventClass.rawValue):captureGapP99=\(formatMs(stats.clientCaptureGapMs.p99))ms " +
                "sendGapP99=\(formatMs(stats.clientSendGapMs.p99))ms " +
                "sendGapMax=\(formatMs(stats.clientSendGapMs.max))ms " +
                "captureToSendP99=\(formatMs(stats.clientCaptureToSendMs.p99))ms " +
                "captureToSendMax=\(formatMs(stats.clientCaptureToSendMs.max))ms " +
                "routes=\(routes) priorityState=\(routeState) " +
                "priorityAckAgeP99=\(formatMs(stats.priorityAckAgeMs.p99))ms " +
                "priorityAckAgeMax=\(formatMs(stats.priorityAckAgeMs.max))ms " +
                "fallbacks=\(stats.clientFallbackCount)"
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
            return "\(eventClass.rawValue):receiveGapP99=\(formatMs(stats.hostReceiveGapMs.p99))ms " +
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
}
