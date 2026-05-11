//
//  MirageHostService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message receiving loop.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
private final class MirageStreamReceiveSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedChunks: [Data] = []
    private var waitingCompletion: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
    private var finished = false

    init(stream: AsyncStream<Data>) {
        Task {
            for await chunk in stream {
                self.push(chunk)
            }
            self.finish()
        }
    }

    func receiveNext(
        _ completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) {
        lock.lock()
        if !bufferedChunks.isEmpty {
            let chunk = bufferedChunks.removeFirst()
            lock.unlock()
            completion(chunk, nil, false, nil)
            return
        }
        if finished {
            lock.unlock()
            completion(nil, nil, true, nil)
            return
        }
        waitingCompletion = completion
        lock.unlock()
    }

    private func push(_ chunk: Data) {
        lock.lock()
        if let waitingCompletion {
            self.waitingCompletion = nil
            lock.unlock()
            waitingCompletion(chunk, nil, false, nil)
            return
        }
        bufferedChunks.append(chunk)
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        let waitingCompletion = waitingCompletion
        self.waitingCompletion = nil
        lock.unlock()
        waitingCompletion?(nil, nil, true, nil)
    }
}

final class HostInputMessageScheduler: @unchecked Sendable {
    private struct PendingMessage {
        let message: ControlMessage
        let streamID: StreamID?
        let priority: Priority

        init(message: ControlMessage, classification: (streamID: StreamID?, priority: Priority)) {
            self.message = message
            self.streamID = classification.streamID
            self.priority = classification.priority
        }
    }

    private struct ReplaceableInputKey: Hashable {
        let streamID: StreamID
        let kind: ReplaceableKind
    }

    private enum Priority: Equatable {
        case protected
        case contactMove
        case replaceable(ReplaceableKind)

        var isReplaceable: Bool {
            if case .replaceable = self { return true }
            return false
        }
    }

    private enum ReplaceableKind: Hashable {
        case mouseMoved
        case mouseDragged
        case rightMouseDragged
        case otherMouseDragged
        case scrollWheel
        case stylusHover
    }

    private static let maxPendingMessages = 256
    private static let maxPendingContactSamples = 4096

    private let inputQueue: DispatchQueue
    private let handler: @Sendable (ControlMessage) -> Void
    private let lock = NSLock()
    private var pendingMessages: [PendingMessage] = []
    private var latestReplaceableInputTimestampByKey: [ReplaceableInputKey: TimeInterval] = [:]
    private var drainScheduled = false

    init(
        inputQueue: DispatchQueue,
        handler: @escaping @Sendable (ControlMessage) -> Void
    ) {
        self.inputQueue = inputQueue
        self.handler = handler
    }

    func enqueue(_ message: ControlMessage) {
        let pending = PendingMessage(message: message, classification: Self.classification(for: message))

        lock.lock()
        append(pending)
        trimPendingMessages()
        guard !drainScheduled else {
            lock.unlock()
            return
        }
        drainScheduled = true
        lock.unlock()

        scheduleDrain()
    }

    private func scheduleDrain() {
        inputQueue.async { [weak self] in
            self?.drainOne()
        }
    }

    private func drainOne() {
        lock.lock()
        guard !pendingMessages.isEmpty else {
            drainScheduled = false
            lock.unlock()
            return
        }
        let pending = pendingMessages.removeFirst()
        let shouldDrop = shouldDropStaleReplaceableInput(pending)
        lock.unlock()

        if !shouldDrop {
            handler(pending.message)
        }

        lock.lock()
        let hasMore = !pendingMessages.isEmpty
        if !hasMore {
            drainScheduled = false
        }
        lock.unlock()

        if hasMore {
            scheduleDrain()
        }
    }

    private func append(_ pending: PendingMessage) {
        if let last = pendingMessages.last,
           last.streamID == pending.streamID,
           let mergedMessage = Self.mergedNativeContinuousScrollMessage(
               olderMessage: last.message,
               newerMessage: pending.message
           ) {
            pendingMessages[pendingMessages.count - 1] = PendingMessage(
                message: mergedMessage,
                classification: Self.classification(for: mergedMessage)
            )
            return
        }

        if Self.hasNativeScrollMetadata(pending.message) {
            pendingMessages.append(pending)
            return
        }

        if case let .replaceable(kind) = pending.priority,
           let last = pendingMessages.last,
           last.streamID == pending.streamID,
           !Self.hasNativeScrollMetadata(last.message),
           last.priority == .replaceable(kind) {
            pendingMessages[pendingMessages.count - 1] = pending
            return
        }

        pendingMessages.append(pending)
    }

    private func trimPendingMessages() {
        while pendingMessages.count > Self.maxPendingMessages {
            if removeFirstPendingMessage(where: { $0.priority.isReplaceable }) { continue }
            if removeFirstPendingMessage(where: { $0.priority == .contactMove }) { continue }
            break
        }

        while pendingContactSampleCount > Self.maxPendingContactSamples {
            if removeFirstPendingMessage(where: { $0.priority == .contactMove }) { continue }
            break
        }
    }

    private var pendingContactSampleCount: Int {
        pendingMessages.reduce(into: 0) { result, pending in
            guard case .contactMove = pending.priority,
                  let inputMessage = try? InputEventMessage.deserializePayload(pending.message.payload),
                  case let .pointerSampleBatch(batch) = inputMessage.event else {
                return
            }
            result += batch.samples.count
        }
    }

    private func removeFirstPendingMessage(where shouldRemove: (PendingMessage) -> Bool) -> Bool {
        guard let index = pendingMessages.firstIndex(where: shouldRemove) else { return false }
        pendingMessages.remove(at: index)
        return true
    }

    private func shouldDropStaleReplaceableInput(_ pending: PendingMessage) -> Bool {
        guard case let .replaceable(kind) = pending.priority,
              let streamID = pending.streamID,
              let inputMessage = try? InputEventMessage.deserializePayload(pending.message.payload) else {
            return false
        }

        let timestamp = inputMessage.event.timestamp
        let key = ReplaceableInputKey(streamID: streamID, kind: kind)
        if let previousTimestamp = latestReplaceableInputTimestampByKey[key],
           timestamp < previousTimestamp {
            return true
        }
        latestReplaceableInputTimestampByKey[key] = timestamp
        return false
    }

    private static func classification(for message: ControlMessage) -> (streamID: StreamID?, priority: Priority) {
        guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else {
            return (nil, .protected)
        }

        switch inputMessage.event {
        case .mouseMoved:
            return (inputMessage.streamID, .replaceable(.mouseMoved))
        case .mouseDragged:
            return (inputMessage.streamID, .replaceable(.mouseDragged))
        case .rightMouseDragged:
            return (inputMessage.streamID, .replaceable(.rightMouseDragged))
        case .otherMouseDragged:
            return (inputMessage.streamID, .replaceable(.otherMouseDragged))
        case let .scrollWheel(event):
            return (inputMessage.streamID, event.isBoundaryScrollEvent ? .protected : .replaceable(.scrollWheel))
        case let .pointerSampleBatch(batch):
            if batch.phase == .hover {
                return (inputMessage.streamID, .replaceable(.stylusHover))
            }
            if batch.phase == .moved {
                return (inputMessage.streamID, .contactMove)
            }
            return (inputMessage.streamID, .protected)
        default:
            return (inputMessage.streamID, .protected)
        }
    }

    private static func hasNativeScrollMetadata(_ message: ControlMessage) -> Bool {
        guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload),
              case let .scrollWheel(event) = inputMessage.event else {
            return false
        }
        return event.hasNativeScrollMetadata
    }

    private static func mergedNativeContinuousScrollMessage(
        olderMessage: ControlMessage,
        newerMessage: ControlMessage
    ) -> ControlMessage? {
        guard olderMessage.type == .inputEvent,
              newerMessage.type == .inputEvent,
              let olderInputMessage = try? InputEventMessage.deserializePayload(olderMessage.payload),
              let newerInputMessage = try? InputEventMessage.deserializePayload(newerMessage.payload),
              olderInputMessage.streamID == newerInputMessage.streamID,
              case let .scrollWheel(olderScrollEvent) = olderInputMessage.event,
              case let .scrollWheel(newerScrollEvent) = newerInputMessage.event,
              let mergedScrollEvent = olderScrollEvent.mergedWithCompatibleNativeContinuousScrollEvent(
                  newerScrollEvent
              ) else {
            return nil
        }

        let mergedInputMessage = InputEventMessage(
            streamID: newerInputMessage.streamID,
            event: .scrollWheel(mergedScrollEvent)
        )
        guard let payload = try? mergedInputMessage.serializePayload() else { return nil }
        return ControlMessage(type: .inputEvent, payload: payload)
    }
}

@MainActor
extension MirageHostService {
    /// Continuously receive and handle control messages from a client.
    func startReceivingFromClient(clientContext: ClientContext, initialBuffer: Data = Data()) {
        let source = MirageStreamReceiveSource(stream: clientContext.controlChannel.incomingBytes)

        let clientID = clientContext.client.id
        let activityTracker = clientLastActivityByID
        recordClientActivity(clientID: clientID)
        let inputScheduler = HostInputMessageScheduler(inputQueue: inputQueue) { [weak self] message in
            guard let self else { return }
            self.handleInputEventFast(message, from: clientContext.client, sessionID: clientContext.sessionID)
        }

        let receiveLoop = HostReceiveLoop(
            clientName: clientContext.client.name,
            maxControlBacklog: 256,
            errorTimeoutSeconds: clientErrorTimeoutSeconds,
            receiveChunk: { completion in
                source.receiveNext { data, context, isComplete, error in
                    if data != nil {
                        activityTracker.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
                    }
                    completion(data, context, isComplete, error)
                }
            },
            onInputMessage: { message in
                inputScheduler.enqueue(message)
            },
            onPingMessage: { _ in
                clientContext.sendBestEffort(ControlMessage(type: .pong))
            },
            onReceiverMediaFeedbackMessage: { [weak self] message in
                guard let self else { return }
                self.receiverMediaFeedbackDiagnostics.withLock { diagnostics in
                    diagnostics.fastPathCount &+= 1
                    diagnostics.logSuppressedCount &+= 1
                }
                guard let feedback = try? message.decode(ReceiverMediaFeedbackMessage.self) else {
                    self.receiverMediaFeedbackDiagnostics.withLock { $0.droppedCount &+= 1 }
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handleReceiverMediaFeedback(feedback)
                }
            },
            onReceiverMediaFeedbackCoalesced: { [weak self] count in
                self?.receiverMediaFeedbackDiagnostics.withLock { $0.coalescedCount &+= count }
            },
            onLifecycleSignal: { [weak self] signal in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch signal {
                    case .disconnect:
                        self.markStreamSetupSessionClosing(clientSessionID: clientContext.sessionID)
                        await self.disconnectClient(
                            clientContext.client,
                            sessionID: clientContext.sessionID,
                            notifyClient: false
                        )
                    case let .cancelStreamSetup(message):
                        let request = (try? message.decode(CancelStreamSetupMessage.self)) ?? CancelStreamSetupMessage()
                        if let startupRequestID = request.startupRequestID {
                            self.cancelStreamSetup(
                                clientSessionID: clientContext.sessionID,
                                startupRequestID: startupRequestID
                            )
                        } else {
                            self.cancelAllStreamSetup(clientSessionID: clientContext.sessionID)
                        }
                    case .terminal:
                        self.markStreamSetupSessionClosing(clientSessionID: clientContext.sessionID)
                        await self.disconnectClient(
                            clientContext.client,
                            sessionID: clientContext.sessionID,
                            notifyClient: false
                        )
                    }
                }
            },
            dispatchControlMessage: { [weak self] message, completion in
                guard let self else {
                    completion()
                    return
                }
                self.dispatchControlWork(clientID: clientContext.client.id, completion: completion) { [weak self] in
                    guard let self else { return }
                    guard let liveClientContext = self.findClientContext(sessionID: clientContext.sessionID) else {
                        return
                    }
                    await self.handleClientMessage(message, from: liveClientContext)
                }
            },
            onTerminal: { [weak self] reason in
                guard let self else { return }
                self.dispatchControlWork(clientID: clientContext.client.id) { [weak self] in
                    guard let self else { return }
                    self.removeReceiveLoop(sessionID: clientContext.sessionID)

                    switch reason {
                    case .complete:
                        MirageLogger.host("Client disconnected")
                    case let .fatalError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(clientContext.client.name) disconnected after fatal transport error: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(clientContext.client.name) fatal connection error - disconnecting: \(error)"
                            )
                        }
                    case let .persistentError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(clientContext.client.name) disconnected after persistent transport errors: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(clientContext.client.name) persistent receive errors - disconnecting: \(error)"
                            )
                        }
                    case let .protocolViolation(reason):
                        MirageLogger.host(
                            "Client \(clientContext.client.name) protocol violation - disconnecting: \(reason)"
                        )
                    case let .receiveBufferOverflow(limit):
                        MirageLogger.error(
                            .host,
                            "Client \(clientContext.client.name) control receive buffer exceeded \(limit) bytes - disconnecting"
                        )
                    }

                    await self.disconnectClient(
                        clientContext.client,
                        sessionID: clientContext.sessionID,
                        notifyClient: false
                    )
                }
            },
            isFatalError: { [weak self] error in
                guard let self else { return true }
                return self.isFatalConnectionError(error)
            }
        )

        self.storeReceiveLoop(receiveLoop, sessionID: clientContext.sessionID)
        receiveLoop.start(initialBuffer: initialBuffer)
    }
}
#endif
