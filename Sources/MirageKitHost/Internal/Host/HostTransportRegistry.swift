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
private final class MediaConnectionScheduler: @unchecked Sendable {
    private struct QueuedPacket {
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
    }

    private let lock = NSLock()
    private let connection: NWConnection
    private let maxPassiveQueueDepth = 1
    private var state = State()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func setStreamActive(_ streamID: StreamID, isActive: Bool) {
        var droppedPackets: [QueuedPacket] = []
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
            }
        }
        lock.unlock()

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
        let packet = QueuedPacket(data: data, onComplete: onComplete)
        if state.activeStreams.contains(streamID) {
            queue.append(packet)
        } else {
            if queue.count >= maxPassiveQueueDepth {
                droppedPacket = queue.removeFirst()
            }
            queue.append(packet)
        }
        state.streamQueues[streamID] = queue
        if !state.sendInFlight {
            state.sendInFlight = true
            shouldKick = true
        }
        lock.unlock()

        droppedPacket?.onComplete?(nil)
        guard shouldKick else { return }
        sendNext()
    }

    func removeStream(_ streamID: StreamID) {
        let removedPackets: [QueuedPacket]
        lock.lock()
        removedPackets = state.streamQueues.removeValue(forKey: streamID) ?? []
        state.streamOrder.removeAll { $0 == streamID }
        state.activeStreams.remove(streamID)
        if state.activeCursor >= state.streamOrder.count {
            state.activeCursor = 0
        }
        if state.passiveCursor >= state.streamOrder.count {
            state.passiveCursor = 0
        }
        lock.unlock()

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
        lock.unlock()

        for packet in packetsToComplete {
            packet.onComplete?(nil)
        }
    }

    private func sendNext() {
        guard let packet = dequeueNextPayload() else {
            lock.lock()
            state.sendInFlight = false
            lock.unlock()
            return
        }

        connection.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            packet.onComplete?(error)
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
