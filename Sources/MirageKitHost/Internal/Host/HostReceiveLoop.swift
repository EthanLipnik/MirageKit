//
//  HostReceiveLoop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import CoreFoundation
import Foundation
import Network
import MirageKit

#if os(macOS)
/// Per-connection receive loop that keeps input ingestion independent from control handling.
final class HostReceiveLoop: @unchecked Sendable {
    enum TerminalReason {
        case complete
        case fatalError(NWError)
        case persistentError(NWError)
        case protocolViolation(String)
        case receiveBufferOverflow(Int)
    }

    private enum QueueEntry {
        case direct(ControlMessage)
        case coalesced(ControlMessageType)
    }

    private struct State {
        var receiveBuffer = Data()
        var entries: [QueueEntry] = []
        var coalesced: [ControlMessageType: ControlMessage] = [:]
        var controlInFlight = false
        var stopped = false
        var firstErrorTime: CFAbsoluteTime?
    }

    private static let coalescedTypes: Set<ControlMessageType> = [
        .displayResolutionChange,
        .streamScaleChange,
        .streamRefreshRateChange,
        .streamEncoderSettingsChange,
    ]

    private let receiveChunk: @Sendable (
        @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) -> Void
    private let clientName: String
    private let maxControlBacklog: Int
    private let maxReceiveBufferBytes: Int
    private let errorTimeoutSeconds: CFAbsoluteTime
    private let state = Locked(State())

    private let onInputMessage: @Sendable (ControlMessage) -> Void
    private let onPingMessage: @Sendable (ControlMessage) -> Void
    private let dispatchControlMessage: @Sendable (ControlMessage, @escaping @Sendable () -> Void) -> Void
    private let onTerminal: @Sendable (TerminalReason) -> Void
    private let isFatalError: @Sendable (NWError) -> Bool

    init(
        connection: NWConnection,
        clientName: String,
        maxControlBacklog: Int = 256,
        maxReceiveBufferBytes: Int = LoomMessageLimits.maxReceiveBufferBytes,
        errorTimeoutSeconds: CFAbsoluteTime = 2.0,
        onInputMessage: @escaping @Sendable (ControlMessage) -> Void,
        onPingMessage: @escaping @Sendable (ControlMessage) -> Void,
        dispatchControlMessage: @escaping @Sendable (ControlMessage, @escaping @Sendable () -> Void) -> Void,
        onTerminal: @escaping @Sendable (TerminalReason) -> Void,
        isFatalError: @escaping @Sendable (NWError) -> Bool
    ) {
        self.clientName = clientName
        self.maxControlBacklog = max(8, maxControlBacklog)
        self.maxReceiveBufferBytes = max(8 * 1024, maxReceiveBufferBytes)
        self.errorTimeoutSeconds = max(0.1, errorTimeoutSeconds)
        self.onInputMessage = onInputMessage
        self.onPingMessage = onPingMessage
        self.dispatchControlMessage = dispatchControlMessage
        self.onTerminal = onTerminal
        self.isFatalError = isFatalError
        receiveChunk = { completion in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: completion)
        }
    }

    init(
        clientName: String,
        maxControlBacklog: Int = 256,
        maxReceiveBufferBytes: Int = LoomMessageLimits.maxReceiveBufferBytes,
        errorTimeoutSeconds: CFAbsoluteTime = 2.0,
        receiveChunk: @escaping @Sendable (
            @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
        ) -> Void,
        onInputMessage: @escaping @Sendable (ControlMessage) -> Void,
        onPingMessage: @escaping @Sendable (ControlMessage) -> Void,
        dispatchControlMessage: @escaping @Sendable (ControlMessage, @escaping @Sendable () -> Void) -> Void,
        onTerminal: @escaping @Sendable (TerminalReason) -> Void,
        isFatalError: @escaping @Sendable (NWError) -> Bool
    ) {
        self.clientName = clientName
        self.maxControlBacklog = max(8, maxControlBacklog)
        self.maxReceiveBufferBytes = max(8 * 1024, maxReceiveBufferBytes)
        self.errorTimeoutSeconds = max(0.1, errorTimeoutSeconds)
        self.receiveChunk = receiveChunk
        self.onInputMessage = onInputMessage
        self.onPingMessage = onPingMessage
        self.dispatchControlMessage = dispatchControlMessage
        self.onTerminal = onTerminal
        self.isFatalError = isFatalError
    }

    func start(initialBuffer: Data = Data()) {
        if !initialBuffer.isEmpty {
            state.withLock { state in
                state.receiveBuffer.append(initialBuffer)
            }
            parseBufferedMessages()
            scheduleNextControlIfNeeded()
        }
        receiveNext()
    }

    func stop() {
        state.withLock { state in
            state.stopped = true
            state.entries.removeAll(keepingCapacity: false)
            state.coalesced.removeAll(keepingCapacity: false)
            state.controlInFlight = false
        }
    }

    private func receiveNext() {
        let isStopped = state.read { $0.stopped }
        guard !isStopped else { return }

        receiveChunk { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.handleReceiveError(error)
                return
            }

            if let data, !data.isEmpty {
                let bufferOverflowed = self.state.withLock { state in
                    state.firstErrorTime = nil
                    state.receiveBuffer.append(data)
                    return state.receiveBuffer.count > self.maxReceiveBufferBytes
                }
                if bufferOverflowed {
                    self.stop()
                    self.onTerminal(.receiveBufferOverflow(self.maxReceiveBufferBytes))
                    return
                }
                self.parseBufferedMessages()
                self.scheduleNextControlIfNeeded()
            }

            if isComplete {
                self.stop()
                self.onTerminal(.complete)
                return
            }

            self.receiveNext()
        }
    }

    private func handleReceiveError(_ error: NWError) {
        if isFatalError(error) {
            stop()
            onTerminal(.fatalError(error))
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let shouldTerminate = state.withLock { state -> Bool in
            if let first = state.firstErrorTime {
                return now - first >= errorTimeoutSeconds
            }
            state.firstErrorTime = now
            return false
        }

        if shouldTerminate {
            stop()
            onTerminal(.persistentError(error))
            return
        }

        MirageLogger.host(
            "Client \(clientName) transient receive error, continuing: \(error)"
        )
        receiveNext()
    }

    private func parseBufferedMessages() {
        var inputMessages: [ControlMessage] = []
        var pingMessages: [ControlMessage] = []
        var controlMessages: [ControlMessage] = []
        var violationReason: String?

        state.withLock { state in
            var parseOffset = 0
            while true {
                switch ControlMessage.deserialize(from: state.receiveBuffer, offset: parseOffset) {
                case let .success(message, consumed):
                    parseOffset += consumed
                    if message.type == .inputEvent {
                        inputMessages.append(message)
                    } else if message.type == .ping {
                        pingMessages.append(message)
                    } else if message.type == .pong {
                        continue
                    } else {
                        controlMessages.append(message)
                    }
                case .needMoreData:
                    if parseOffset > 0 {
                        state.receiveBuffer.removeSubrange(0 ..< parseOffset)
                    }
                    return
                case let .invalidFrame(reason):
                    violationReason = reason
                    state.receiveBuffer.removeAll(keepingCapacity: false)
                    return
                }
            }
        }

        if let violationReason {
            stop()
            onTerminal(.protocolViolation(violationReason))
            return
        }

        for message in inputMessages {
            onInputMessage(message)
        }

        for message in pingMessages {
            onPingMessage(message)
        }

        if !controlMessages.isEmpty {
            state.withLock { state in
                for message in controlMessages {
                    enqueueControl(message, state: &state)
                }
            }
        }
    }

    private func enqueueControl(_ message: ControlMessage, state: inout State) {
        let type = message.type
        if Self.coalescedTypes.contains(type) {
            if state.coalesced[type] == nil {
                state.entries.append(.coalesced(type))
            }
            state.coalesced[type] = message
        } else {
            if state.entries.count >= maxControlBacklog {
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping newest non-coalesced message \(type)"
                )
                return
            }
            state.entries.append(.direct(message))
        }

        while state.entries.count > maxControlBacklog {
            if let index = state.entries.firstIndex(where: {
                if case .coalesced = $0 {
                    return true
                }
                return false
            }) {
                let entry = state.entries.remove(at: index)
                if case let .coalesced(coalescedType) = entry {
                    state.coalesced.removeValue(forKey: coalescedType)
                }
                continue
            }
            break
        }
    }

    private func scheduleNextControlIfNeeded() {
        let nextMessage: ControlMessage? = state.withLock { state in
            guard !state.stopped else { return nil }
            guard !state.controlInFlight else { return nil }
            guard !state.entries.isEmpty else { return nil }

            state.controlInFlight = true
            let next = state.entries.removeFirst()
            switch next {
            case let .direct(message):
                return message
            case let .coalesced(type):
                return state.coalesced.removeValue(forKey: type)
            }
        }

        guard let message = nextMessage else { return }

        dispatchControlMessage(message) { [weak self] in
            guard let self else { return }
            self.state.withLock { state in
                state.controlInFlight = false
            }
            self.scheduleNextControlIfNeeded()
        }
    }
}
#endif
