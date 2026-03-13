//
//  HostTransportRegistry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
enum HostVideoTransportPressure: Int, Comparable {
    case normal = 0
    case elevated = 1
    case critical = 2

    static func < (lhs: HostVideoTransportPressure, rhs: HostVideoTransportPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HostVideoTransportDiagnostics {
    static let backlogElevatedPacketCount = 128
    static let backlogCriticalPacketCount = 384
    static let backlogElevatedBytes = 512 * 1_024
    static let backlogCriticalBytes = 2 * 1_024 * 1_024
    static let sendLatencyElevatedMs = 40.0
    static let sendLatencyCriticalMs = 150.0
    static let repeatedProblemLogInterval: CFAbsoluteTime = 1.0
    static let watchdogPollInterval: Duration = .milliseconds(250)

    static func backlogPressure(
        pendingPackets: Int,
        pendingBytes: Int
    ) -> HostVideoTransportPressure {
        if pendingPackets >= backlogCriticalPacketCount || pendingBytes >= backlogCriticalBytes {
            return .critical
        }
        if pendingPackets >= backlogElevatedPacketCount || pendingBytes >= backlogElevatedBytes {
            return .elevated
        }
        return .normal
    }

    static func sendLatencyPressure(elapsedMs: Double) -> HostVideoTransportPressure {
        if elapsedMs >= sendLatencyCriticalMs {
            return .critical
        }
        if elapsedMs >= sendLatencyElevatedMs {
            return .elevated
        }
        return .normal
    }
}

private final class MediaConnectionScheduler: @unchecked Sendable {
    private struct QueuedPacket {
        let streamID: StreamID
        let data: Data
        let onComplete: (@Sendable (NWError?) -> Void)?
    }

    private struct State {
        var streamQueues: [StreamID: [QueuedPacket]] = [:]
        var streamOrder: [StreamID] = []
        var activeStreams: Set<StreamID> = []
        var activeCursor = 0
        var passiveCursor = 0
        var sendInFlight = false
        var isClosed = false
        var pendingPacketCount = 0
        var pendingByteCount = 0
        var backlogPressure: HostVideoTransportPressure = .normal
        var lastBacklogLogTime: CFAbsoluteTime = 0
        var lastLatencyLogTime: CFAbsoluteTime = 0
        var inFlightStreamID: StreamID?
        var inFlightPacketByteCount = 0
        var inFlightStartedAt: CFAbsoluteTime = 0
        var sendStallPressure: HostVideoTransportPressure = .normal
    }

    private let lock = NSLock()
    private let connection: NWConnection
    private let maxPassiveQueueDepth = 1
    private var state = State()
    private var diagnosticsTask: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
        diagnosticsTask = Task(priority: .utility) { [weak self] in
            await self?.runDiagnosticsLoop()
        }
    }

    deinit {
        diagnosticsTask?.cancel()
    }

    func setStreamActive(_ streamID: StreamID, isActive: Bool) {
        var droppedPackets: [QueuedPacket] = []
        var backlogLog: String?
        lock.lock()
        if isActive {
            state.activeStreams.insert(streamID)
        } else {
            state.activeStreams.remove(streamID)
            if var queue = state.streamQueues[streamID], queue.count > maxPassiveQueueDepth {
                let keepCount = maxPassiveQueueDepth
                droppedPackets = Array(queue.prefix(max(0, queue.count - keepCount)))
                queue = Array(queue.suffix(keepCount))
                state.streamQueues[streamID] = queue
                for packet in droppedPackets {
                    state.pendingPacketCount = max(0, state.pendingPacketCount - 1)
                    state.pendingByteCount = max(0, state.pendingByteCount - packet.data.count)
                }
                backlogLog = backlogTransitionMessageLocked(now: CFAbsoluteTimeGetCurrent())
            }
        }
        lock.unlock()

        if let backlogLog {
            MirageLogger.stream(backlogLog)
        }
        for packet in droppedPackets {
            packet.onComplete?(nil)
        }
    }

    func enqueue(
        streamID: StreamID,
        data: Data,
        onComplete: (@Sendable (NWError?) -> Void)?
    ) {
        var shouldKick = false
        var droppedPacket: QueuedPacket?
        var backlogLog: String?
        lock.lock()
        if state.isClosed {
            lock.unlock()
            onComplete?(nil)
            return
        }
        if !state.streamOrder.contains(streamID) {
            state.streamOrder.append(streamID)
        }
        var queue = state.streamQueues[streamID] ?? []
        let packet = QueuedPacket(streamID: streamID, data: data, onComplete: onComplete)
        if state.activeStreams.contains(streamID) {
            queue.append(packet)
        } else {
            if queue.count >= maxPassiveQueueDepth {
                droppedPacket = queue.removeFirst()
                if let droppedPacket {
                    state.pendingPacketCount = max(0, state.pendingPacketCount - 1)
                    state.pendingByteCount = max(0, state.pendingByteCount - droppedPacket.data.count)
                }
            }
            queue.append(packet)
        }
        state.streamQueues[streamID] = queue
        state.pendingPacketCount += 1
        state.pendingByteCount += data.count
        backlogLog = backlogTransitionMessageLocked(now: CFAbsoluteTimeGetCurrent())
        if !state.sendInFlight {
            state.sendInFlight = true
            shouldKick = true
        }
        lock.unlock()

        if let backlogLog {
            MirageLogger.stream(backlogLog)
        }
        droppedPacket?.onComplete?(nil)
        guard shouldKick else { return }
        sendNext()
    }

    func removeStream(_ streamID: StreamID) {
        let removedPackets: [QueuedPacket]
        var backlogLog: String?
        lock.lock()
        removedPackets = state.streamQueues.removeValue(forKey: streamID) ?? []
        state.streamOrder.removeAll { $0 == streamID }
        state.activeStreams.remove(streamID)
        for packet in removedPackets {
            state.pendingPacketCount = max(0, state.pendingPacketCount - 1)
            state.pendingByteCount = max(0, state.pendingByteCount - packet.data.count)
        }
        backlogLog = backlogTransitionMessageLocked(now: CFAbsoluteTimeGetCurrent())
        if state.activeCursor >= state.streamOrder.count {
            state.activeCursor = 0
        }
        if state.passiveCursor >= state.streamOrder.count {
            state.passiveCursor = 0
        }
        lock.unlock()

        if let backlogLog {
            MirageLogger.stream(backlogLog)
        }
        for packet in removedPackets {
            packet.onComplete?(nil)
        }
    }

    func close() {
        let packetsToComplete: [QueuedPacket]
        lock.lock()
        state.isClosed = true
        packetsToComplete = state.streamQueues.values.flatMap { $0 }
        state.streamQueues.removeAll(keepingCapacity: false)
        state.streamOrder.removeAll(keepingCapacity: false)
        state.activeStreams.removeAll(keepingCapacity: false)
        state.pendingPacketCount = 0
        state.pendingByteCount = 0
        state.backlogPressure = .normal
        state.inFlightStreamID = nil
        state.inFlightPacketByteCount = 0
        state.inFlightStartedAt = 0
        state.sendStallPressure = .normal
        lock.unlock()
        diagnosticsTask?.cancel()

        for packet in packetsToComplete {
            packet.onComplete?(nil)
        }
    }

    private func sendNext() {
        guard let packet = dequeueNextPayload() else {
            lock.lock()
            state.sendInFlight = false
            state.inFlightStreamID = nil
            state.inFlightPacketByteCount = 0
            state.inFlightStartedAt = 0
            state.sendStallPressure = .normal
            lock.unlock()
            return
        }

        lock.lock()
        state.inFlightStreamID = packet.streamID
        state.inFlightPacketByteCount = packet.data.count
        state.inFlightStartedAt = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        connection.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            let completionLog = self?.recordSendCompletion(packet: packet)
            packet.onComplete?(error)
            if let completionLog {
                MirageLogger.stream(completionLog)
            }
            self?.sendNext()
        })
    }

    private func dequeueNextPayload() -> QueuedPacket? {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isClosed else { return nil }
        guard !state.streamOrder.isEmpty else { return nil }

        if let payload = dequeueFrom(activeOnly: true) { return payload }
        return dequeueFrom(activeOnly: false)
    }

    private func dequeueFrom(activeOnly: Bool) -> QueuedPacket? {
        guard !state.streamOrder.isEmpty else { return nil }
        let count = state.streamOrder.count
        var visited = 0
        while visited < count {
            let index: Int
            if activeOnly {
                index = state.activeCursor % count
                state.activeCursor = (state.activeCursor + 1) % max(1, count)
            } else {
                index = state.passiveCursor % count
                state.passiveCursor = (state.passiveCursor + 1) % max(1, count)
            }
            visited += 1

            let streamID = state.streamOrder[index]
            let isActive = state.activeStreams.contains(streamID)
            if activeOnly != isActive { continue }
            guard var queue = state.streamQueues[streamID], !queue.isEmpty else { continue }
            let packet = queue.removeFirst()
            if queue.isEmpty {
                state.streamQueues.removeValue(forKey: streamID)
            } else {
                state.streamQueues[streamID] = queue
            }
            return packet
        }
        return nil
    }

    private func runDiagnosticsLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: HostVideoTransportDiagnostics.watchdogPollInterval)
            if let stallLog = stalledSendMessageIfNeeded(now: CFAbsoluteTimeGetCurrent()) {
                MirageLogger.stream(stallLog)
            }
        }
    }

    private func recordSendCompletion(packet: QueuedPacket) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        var logMessages: [String] = []

        lock.lock()
        let elapsedMs = state.inFlightStartedAt > 0
            ? max(0, (now - state.inFlightStartedAt) * 1_000)
            : 0
        let latencyPressure = HostVideoTransportDiagnostics.sendLatencyPressure(elapsedMs: elapsedMs)
        if latencyPressure > .normal, state.sendStallPressure == .normal {
            logMessages.append(
                "Video export send latency \(latencyPressure == .critical ? "critical" : "elevated"): " +
                    "stream \(packet.streamID), latency=\(Int(elapsedMs.rounded()))ms, " +
                    "pending=\(state.pendingPacketCount) packets (\(pendingKilobytesLocked())KB)"
            )
            state.lastLatencyLogTime = now
        } else if state.sendStallPressure > .normal {
            logMessages.append(
                "Video export send recovered: stream \(packet.streamID), latency=\(Int(elapsedMs.rounded()))ms, " +
                    "pending=\(max(0, state.pendingPacketCount - 1)) packets"
            )
            state.lastLatencyLogTime = now
        }

        state.pendingPacketCount = max(0, state.pendingPacketCount - 1)
        state.pendingByteCount = max(0, state.pendingByteCount - packet.data.count)
        state.inFlightStreamID = nil
        state.inFlightPacketByteCount = 0
        state.inFlightStartedAt = 0
        state.sendStallPressure = .normal

        if let backlogLog = backlogTransitionMessageLocked(now: now) {
            logMessages.append(backlogLog)
        }
        lock.unlock()

        guard !logMessages.isEmpty else { return nil }
        return logMessages.joined(separator: "\n")
    }

    private func stalledSendMessageIfNeeded(now: CFAbsoluteTime) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard state.sendInFlight,
              !state.isClosed,
              state.inFlightStartedAt > 0,
              let streamID = state.inFlightStreamID else {
            return nil
        }

        let elapsedMs = max(0, (now - state.inFlightStartedAt) * 1_000)
        let pressure = HostVideoTransportDiagnostics.sendLatencyPressure(elapsedMs: elapsedMs)
        guard pressure > .normal else { return nil }

        let shouldLog = pressure > state.sendStallPressure ||
            state.lastLatencyLogTime == 0 ||
            now - state.lastLatencyLogTime >= HostVideoTransportDiagnostics.repeatedProblemLogInterval
        guard shouldLog else { return nil }

        state.sendStallPressure = pressure
        state.lastLatencyLogTime = now
        return "Video export send stalled (\(pressure == .critical ? "critical" : "elevated")): " +
            "stream \(streamID), elapsed=\(Int(elapsedMs.rounded()))ms, " +
            "packet=\(state.inFlightPacketByteCount)B, pending=\(state.pendingPacketCount) packets (\(pendingKilobytesLocked())KB)"
    }

    private func backlogTransitionMessageLocked(now: CFAbsoluteTime) -> String? {
        let nextPressure = HostVideoTransportDiagnostics.backlogPressure(
            pendingPackets: state.pendingPacketCount,
            pendingBytes: state.pendingByteCount
        )
        guard nextPressure != state.backlogPressure else { return nil }

        let previousPressure = state.backlogPressure
        state.backlogPressure = nextPressure
        state.lastBacklogLogTime = now

        if nextPressure == .normal, previousPressure > .normal {
            return "Video export backlog recovered: pending=\(state.pendingPacketCount) packets (\(pendingKilobytesLocked())KB)"
        }

        guard nextPressure > .normal else { return nil }
        return "Video export backlog \(nextPressure == .critical ? "critical" : "elevated"): " +
            "pending=\(state.pendingPacketCount) packets (\(pendingKilobytesLocked())KB), " +
            "streams=\(state.streamQueues.count), active=\(state.activeStreams.count)"
    }

    private func pendingKilobytesLocked() -> Int {
        Int((Double(state.pendingByteCount) / 1_024.0).rounded())
    }
}

/// Thread-safe registry for host TCP/UDP data transport sockets.
final class HostTransportRegistry: @unchecked Sendable {
    private struct State {
        var videoByStream: [StreamID: NWConnection] = [:]
        var videoStreamIsActive: [StreamID: Bool] = [:]
        var videoSchedulersByConnectionID: [ObjectIdentifier: MediaConnectionScheduler] = [:]
        var audioByClientID: [UUID: NWConnection] = [:]
        var qualityByClientID: [UUID: NWConnection] = [:]
    }

    private let state = Locked(State())

    func registerVideoConnection(_ connection: NWConnection, streamID: StreamID) {
        state.withLock { state in
            state.videoByStream[streamID] = connection
            let connectionID = ObjectIdentifier(connection)
            if state.videoSchedulersByConnectionID[connectionID] == nil {
                state.videoSchedulersByConnectionID[connectionID] = MediaConnectionScheduler(connection: connection)
            }
            let isActive = state.videoStreamIsActive[streamID] ?? false
            state.videoSchedulersByConnectionID[connectionID]?.setStreamActive(streamID, isActive: isActive)
        }
    }

    @discardableResult
    func unregisterVideoConnection(streamID: StreamID) -> NWConnection? {
        state.withLock { state in
            let removed = state.videoByStream.removeValue(forKey: streamID)
            state.videoStreamIsActive.removeValue(forKey: streamID)
            if let removed {
                let connectionID = ObjectIdentifier(removed)
                state.videoSchedulersByConnectionID[connectionID]?.removeStream(streamID)
                let stillBound = state.videoByStream.values.contains { ObjectIdentifier($0) == connectionID }
                if !stillBound {
                    state.videoSchedulersByConnectionID[connectionID]?.close()
                    state.videoSchedulersByConnectionID.removeValue(forKey: connectionID)
                }
            }
            return removed
        }
    }

    func setVideoStreamActive(streamID: StreamID, isActive: Bool) {
        state.withLock { state in
            state.videoStreamIsActive[streamID] = isActive
            guard let connection = state.videoByStream[streamID] else { return }
            let connectionID = ObjectIdentifier(connection)
            state.videoSchedulersByConnectionID[connectionID]?.setStreamActive(streamID, isActive: isActive)
        }
    }

    func registerAudioConnection(_ connection: NWConnection, clientID: UUID) {
        state.withLock { $0.audioByClientID[clientID] = connection }
    }

    @discardableResult
    func unregisterAudioConnection(clientID: UUID) -> NWConnection? {
        state.withLock { $0.audioByClientID.removeValue(forKey: clientID) }
    }

    func registerQualityConnection(_ connection: NWConnection, clientID: UUID) {
        state.withLock { $0.qualityByClientID[clientID] = connection }
    }

    @discardableResult
    func unregisterQualityConnection(clientID: UUID) -> NWConnection? {
        state.withLock { $0.qualityByClientID.removeValue(forKey: clientID) }
    }

    @discardableResult
    func unregisterAllConnections(clientID: UUID) -> [NWConnection] {
        state.withLock { state in
            var removed: [NWConnection] = []
            if let audio = state.audioByClientID.removeValue(forKey: clientID) {
                removed.append(audio)
            }
            if let quality = state.qualityByClientID.removeValue(forKey: clientID) {
                removed.append(quality)
            }
            return removed
        }
    }

    func sendVideo(
        streamID: StreamID,
        data: Data,
        onComplete: (@Sendable (NWError?) -> Void)? = nil
    ) {
        let scheduler: MediaConnectionScheduler? = state.read { state in
            guard let connection = state.videoByStream[streamID] else { return nil }
            return state.videoSchedulersByConnectionID[ObjectIdentifier(connection)]
        }
        guard let scheduler else {
            onComplete?(nil)
            return
        }

        scheduler.enqueue(streamID: streamID, data: data, onComplete: onComplete)
    }

    func sendAudio(clientID: UUID, data: Data) {
        guard let connection = state.read({ $0.audioByClientID[clientID] }) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func sendQuality(clientID: UUID, data: Data) {
        guard let connection = state.read({ $0.qualityByClientID[clientID] }) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func hasVideoConnection(streamID: StreamID) -> Bool {
        state.read { $0.videoByStream[streamID] != nil }
    }

    func hasAudioConnection(clientID: UUID) -> Bool {
        state.read { $0.audioByClientID[clientID] != nil }
    }
}
#endif
