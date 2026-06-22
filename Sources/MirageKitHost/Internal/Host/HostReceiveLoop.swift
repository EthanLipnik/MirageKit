//
//  HostReceiveLoop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
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
import CoreFoundation
import Foundation
import Network

#if os(macOS)
/// Per-connection receive loop that keeps input ingestion independent from control handling.
final class HostReceiveLoop: @unchecked Sendable {
    /// Terminal receive-loop outcomes reported to the host connection lifecycle.
    enum TerminalReason {
        /// The remote side completed the connection normally.
        case complete
        /// A transport error classified as immediately fatal.
        case fatalError(NWError)
        /// A transient transport error persisted past the configured timeout.
        case persistentError(NWError)
        /// Incoming bytes did not contain a valid framed control message.
        case protocolViolation(String)
        /// Buffered receive data exceeded the configured safety cap.
        case receiveBufferOverflow(Int)
    }

    /// Lifecycle events that should bypass normal control-message queueing.
    enum LifecycleSignal {
        /// Client requested disconnect.
        case disconnect(MirageWire.ControlMessage)
        /// Client cancelled an in-flight stream setup.
        case cancelStreamSetup(MirageWire.ControlMessage)
        /// Client acknowledged stream startup readiness.
        case streamReady(MirageWire.ControlMessage)
        /// Receive loop reached a terminal state.
        case terminal(TerminalReason)
    }

    /// Internal queue entry used to preserve ordering while coalescing noisy control updates.
    private enum QueueEntry {
        case direct(MirageWire.ControlMessage)
        case coalesced(CoalescedKey)
        case input(MirageWire.ControlMessage)
    }

    private struct CoalescedKey: Hashable, CustomStringConvertible {
        let type: MirageWire.ControlMessageType
        let streamID: StreamID?

        var description: String {
            if let streamID {
                "\(type)(stream=\(streamID))"
            } else {
                "\(type)"
            }
        }
    }

    /// Mutable receive-loop state protected by `Locked`.
    private struct State {
        var receiveBuffer = Data()
        var entries: [QueueEntry] = []
        var coalesced: [CoalescedKey: MirageWire.ControlMessage] = [:]
        var controlInFlight = false
        var clipboardInputBarrierDepth = 0
        var stopped = false
        var firstErrorTime: CFAbsoluteTime?
    }

    private static let coalescedTypes: Set<MirageWire.ControlMessageType> = [
        .displayResolutionChange,
        .streamScaleChange,
        .streamRefreshRateChange,
        .streamEncoderSettingsChange,
        .receiverMediaFeedback,
    ]

    private static let highPriorityDirectTypes: Set<MirageWire.ControlMessageType> = [
        .disconnect,
        .cancelStreamSetup,
        .hostSupportLogArchiveRequest,
    ]

    private let receiveChunk: @Sendable (
        @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) -> Void
    private let clientName: String
    private let maxControlBacklog: Int
    private let maxReceiveBufferBytes: Int
    private let errorTimeoutSeconds: CFAbsoluteTime
    private let state = Locked(State())

    private let onInputMessage: @Sendable (MirageWire.ControlMessage) -> Void
    private let onPingMessage: @Sendable () -> Void
    private let onLifecycleSignal: @Sendable (LifecycleSignal) -> Void
    private let dispatchControlMessage: @Sendable (MirageWire.ControlMessage, @escaping @Sendable () -> Void) -> Void
    private let onTerminal: @Sendable (TerminalReason) -> Void
    private let isFatalError: @Sendable (NWError) -> Bool

    init(
        clientName: String,
        maxControlBacklog: Int = 256,
        maxReceiveBufferBytes: Int = MirageControlMessageLimits.maxReceiveBufferBytes,
        errorTimeoutSeconds: CFAbsoluteTime = 2.0,
        receiveChunk: @escaping @Sendable (
            @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
        ) -> Void,
        onInputMessage: @escaping @Sendable (MirageWire.ControlMessage) -> Void,
        onPingMessage: @escaping @Sendable () -> Void,
        onLifecycleSignal: @escaping @Sendable (LifecycleSignal) -> Void = { _ in },
        dispatchControlMessage: @escaping @Sendable (MirageWire.ControlMessage, @escaping @Sendable () -> Void) -> Void,
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
        self.onLifecycleSignal = onLifecycleSignal
        self.dispatchControlMessage = dispatchControlMessage
        self.onTerminal = onTerminal
        self.isFatalError = isFatalError
    }

    /// Starts receiving, optionally parsing bytes already read by connection setup.
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

    /// Stops receiving and clears queued work.
    func stop() {
        state.withLock { state in
            state.stopped = true
            state.entries.removeAll(keepingCapacity: false)
            state.coalesced.removeAll(keepingCapacity: false)
            state.controlInFlight = false
            state.clipboardInputBarrierDepth = 0
        }
    }

    /// Requests the next network chunk unless the loop has stopped.
    private func receiveNext() {
        let isStopped = state.read { $0.stopped }
        guard !isStopped else { return }

        receiveChunk { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                handleReceiveError(error)
                return
            }

            if let data, !data.isEmpty {
                let bufferOverflowed = state.withLock { state in
                    state.firstErrorTime = nil
                    state.receiveBuffer.append(data)
                    return state.receiveBuffer.count > self.maxReceiveBufferBytes
                }
                if bufferOverflowed {
                    stop()
                    onLifecycleSignal(.terminal(.receiveBufferOverflow(maxReceiveBufferBytes)))
                    onTerminal(.receiveBufferOverflow(maxReceiveBufferBytes))
                    return
                }
                parseBufferedMessages()
                scheduleNextControlIfNeeded()
            }

            if isComplete {
                stop()
                onLifecycleSignal(.terminal(.complete))
                onTerminal(.complete)
                return
            }

            receiveNext()
        }
    }

    /// Handles fatal and persistent receive errors while tolerating short transient failures.
    private func handleReceiveError(_ error: NWError) {
        if isFatalError(error) {
            stop()
            onLifecycleSignal(.terminal(.fatalError(error)))
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
            onLifecycleSignal(.terminal(.persistentError(error)))
            onTerminal(.persistentError(error))
            return
        }

        MirageLogger.host(
            "Client \(clientName) transient receive error, continuing: \(error)"
        )
        receiveNext()
    }

    /// Parses buffered bytes into immediate input, ping callbacks, and queued control messages.
    private func parseBufferedMessages() {
        var immediateInputMessages: [MirageWire.ControlMessage] = []
        var pingMessageCount = 0
        var violationReason: String?

        state.withLock { state in
            var parseOffset = 0
            while true {
                switch MirageWire.ControlMessage.deserialize(from: state.receiveBuffer, offset: parseOffset) {
                case let .success(message, consumed):
                    parseOffset += consumed
                    if message.type == .inputEvent || message.type == .priorityInputEvent {
                        if state.clipboardInputBarrierDepth > 0 {
                            enqueueInput(message, state: &state)
                        } else {
                            immediateInputMessages.append(message)
                        }
                    } else if message.type == .ping {
                        pingMessageCount += 1
                    } else if message.type == .pong {
                        continue
                    } else {
                        let shouldEnqueue = publishLifecycleSignalIfNeeded(for: message)
                        guard shouldEnqueue else { continue }
                        let enqueued = enqueueControl(message, state: &state)
                        if message.type == .sharedClipboardUpdate, enqueued {
                            state.clipboardInputBarrierDepth += 1
                        }
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
            onLifecycleSignal(.terminal(.protocolViolation(violationReason)))
            onTerminal(.protocolViolation(violationReason))
            return
        }

        for message in immediateInputMessages {
            onInputMessage(message)
        }

        for _ in 0 ..< pingMessageCount {
            onPingMessage()
        }
    }

    /// Enqueues a control message, coalescing noisy update types when possible.
    private func enqueueControl(_ message: MirageWire.ControlMessage, state: inout State) -> Bool {
        let type = message.type
        if Self.coalescedTypes.contains(type) {
            let key = Self.coalescedKey(for: message)
            if state.coalesced[key] == nil {
                state.entries.append(.coalesced(key))
            }
            state.coalesced[key] = message
            trimCoalescedBacklog(state: &state)
            return true
        } else {
            if state.entries.count >= maxControlBacklog {
                if Self.highPriorityDirectTypes.contains(type) {
                    discardQueuedMessageToPreserveHighPriorityControl(type, state: &state)
                }
            }
            if state.entries.count >= maxControlBacklog {
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping newest non-coalesced message \(type)"
                )
                return false
            }
            state.entries.append(.direct(message))
            return true
        }
    }

    /// Emits signals for control messages that need immediate host-side handling.
    /// Returns whether the message should still enter the ordered control queue.
    private func publishLifecycleSignalIfNeeded(for message: MirageWire.ControlMessage) -> Bool {
        switch message.type {
        case .disconnect:
            onLifecycleSignal(.disconnect(message))
            return true
        case .cancelStreamSetup:
            onLifecycleSignal(.cancelStreamSetup(message))
            return true
        case .streamReady:
            onLifecycleSignal(.streamReady(message))
            return false
        default:
            return true
        }
    }

    /// Queues input behind a clipboard barrier while preserving newer input under backlog pressure.
    private func enqueueInput(_ message: MirageWire.ControlMessage, state: inout State) {
        if state.entries.count >= maxControlBacklog {
            discardQueuedMessageToPreserveInput(state: &state)
        }
        if state.entries.count >= maxControlBacklog {
            MirageLogger.host(
                "Client \(clientName) control backlog full; dropping input queued behind clipboard update"
            )
            return
        }
        state.entries.append(.input(message))
    }

    /// Drops the least important queued item so delayed input can still be delivered.
    private func discardQueuedMessageToPreserveInput(state: inout State) {
        if let index = state.entries.firstIndex(where: {
            if case .coalesced = $0 {
                return true
            }
            return false
        }) {
            let entry = state.entries.remove(at: index)
            if case let .coalesced(coalescedKey) = entry {
                state.coalesced.removeValue(forKey: coalescedKey)
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping stale \(coalescedKey) to preserve input"
                )
            }
            return
        }

        if let index = state.entries.firstIndex(where: {
            if case let .direct(message) = $0 {
                return message.type != .sharedClipboardUpdate
            }
            return false
        }) {
            let entry = state.entries.remove(at: index)
            if case let .direct(message) = entry {
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping queued \(message.type) to preserve input"
                )
            }
            return
        }

        if let index = state.entries.firstIndex(where: {
            if case .input = $0 {
                return true
            }
            return false
        }) {
            state.entries.remove(at: index)
            MirageLogger.host(
                "Client \(clientName) control backlog full; dropping older queued input to preserve latest input"
            )
        }
    }

    private func discardQueuedMessageToPreserveHighPriorityControl(
        _ type: MirageWire.ControlMessageType,
        state: inout State
    ) {
        if let index = state.entries.firstIndex(where: {
            if case .coalesced = $0 {
                return true
            }
            return false
        }) {
            let entry = state.entries.remove(at: index)
            if case let .coalesced(coalescedKey) = entry {
                state.coalesced.removeValue(forKey: coalescedKey)
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping stale \(coalescedKey) to preserve \(type)"
                )
            }
            return
        }

        if let index = state.entries.firstIndex(where: {
            if case let .direct(message) = $0 {
                return !Self.highPriorityDirectTypes.contains(message.type)
            }
            return false
        }) {
            let entry = state.entries.remove(at: index)
            if case let .direct(message) = entry {
                MirageLogger.host(
                    "Client \(clientName) control backlog full; dropping queued \(message.type) to preserve \(type)"
                )
            }
        }
    }

    /// Trims stale coalesced control entries when the queue grows past the backlog cap.
    private func trimCoalescedBacklog(state: inout State) {
        while state.entries.count > maxControlBacklog {
            if let index = state.entries.firstIndex(where: {
                if case .coalesced = $0 {
                    return true
                }
                return false
            }) {
                let entry = state.entries.remove(at: index)
                if case let .coalesced(coalescedKey) = entry {
                    state.coalesced.removeValue(forKey: coalescedKey)
                }
                continue
            }
            break
        }
    }

    /// Starts dispatching the next queued control or delayed input message when idle.
    private func scheduleNextControlIfNeeded() {
        enum ScheduledEntry {
            case control(MirageWire.ControlMessage)
            case input(MirageWire.ControlMessage)
        }

        let nextEntry: ScheduledEntry? = state.withLock { state in
            guard !state.stopped else { return nil }
            guard !state.controlInFlight else { return nil }
            guard !state.entries.isEmpty else { return nil }

            state.controlInFlight = true
            let next = state.entries.removeFirst()
            switch next {
            case let .direct(message):
                return .control(message)
            case let .coalesced(key):
                guard let message = state.coalesced.removeValue(forKey: key) else {
                    state.controlInFlight = false
                    return nil
                }
                return .control(message)
            case let .input(message):
                return .input(message)
            }
        }

        guard let nextEntry else { return }

        switch nextEntry {
        case let .control(message):
            dispatchControlMessage(message) { [weak self] in
                self?.finishScheduledEntry(controlType: message.type)
            }
        case let .input(message):
            onInputMessage(message)
            finishScheduledEntry(controlType: nil)
        }
    }

    /// Marks the current queued item complete and advances the queue.
    private func finishScheduledEntry(controlType: MirageWire.ControlMessageType?) {
        state.withLock { state in
            state.controlInFlight = false
            if controlType == .sharedClipboardUpdate, state.clipboardInputBarrierDepth > 0 {
                state.clipboardInputBarrierDepth -= 1
            }
        }
        scheduleNextControlIfNeeded()
    }

    private static func coalescedKey(for message: MirageWire.ControlMessage) -> CoalescedKey {
        guard message.type == .receiverMediaFeedback,
              let feedback = try? message.decode(MirageWire.ReceiverMediaFeedbackMessage.self) else {
            return CoalescedKey(type: message.type, streamID: nil)
        }
        return CoalescedKey(type: message.type, streamID: feedback.streamID)
    }
}
#endif
