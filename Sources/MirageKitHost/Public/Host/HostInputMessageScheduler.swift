//
//  HostInputMessageScheduler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Coalesces high-rate input messages before dispatching them on the host input queue.
final class HostInputMessageScheduler: @unchecked Sendable {
    /// Input message plus its stream affinity and scheduling priority.
    private struct PendingMessage {
        let message: ControlMessage
        let streamID: StreamID?
        let priority: Priority

        init(message: ControlMessage, classification: (streamID: StreamID?, priority: Priority)) {
            self.message = message
            streamID = classification.streamID
            priority = classification.priority
        }
    }

    /// Identity for replaceable input streams tracked by timestamp.
    private struct ReplaceableInputKey: Hashable {
        let streamID: StreamID
        let kind: ReplaceableKind
    }

    /// How aggressively a pending input message may be coalesced or dropped under backlog pressure.
    private enum Priority: Equatable {
        case protected
        case pointerMove
        case contactMove
        case replaceable(ReplaceableKind)

        var isReplaceable: Bool {
            if case .replaceable = self { return true }
            return false
        }
    }

    /// Input event families where only the latest sample of a stream is needed.
    private enum ReplaceableKind: Hashable {
        case scrollWheel
    }

    private static let maxPendingMessages = 256
    private static let maxPendingContactSamples = 4096
    private static let maxMessagesPerDrain = 16

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

    /// Queues a control message and schedules the serial drain if needed.
    func enqueue(_ message: ControlMessage) {
        let pending = PendingMessage(message: message, classification: Self.classification(for: message))

        lock.lock()
        append(pending)
        trimPendingMessages()
        let shouldScheduleDrain: Bool
        if drainScheduled {
            shouldScheduleDrain = false
        } else {
            drainScheduled = true
            shouldScheduleDrain = true
        }
        lock.unlock()

        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    /// Schedules a bounded pending-message drain on the input queue.
    private func scheduleDrain() {
        inputQueue.async { [weak self] in
            self?.drainBatch()
        }
    }

    /// Emits a bounded burst of queued messages, then reschedules itself if backlog remains.
    private func drainBatch() {
        var drainedMessages = 0
        while drainedMessages < Self.maxMessagesPerDrain {
            lock.lock()
            let pending: PendingMessage?
            if pendingMessages.isEmpty {
                drainScheduled = false
                pending = nil
            } else {
                pending = pendingMessages.removeFirst()
            }
            let shouldDrop = pending.map(shouldDropStaleReplaceableInput) ?? false
            lock.unlock()

            guard let pending else { return }

            if !shouldDrop {
                handler(pending.message)
            }
            drainedMessages += 1
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

    /// Adds `pending`, merging adjacent scroll packets and preserving pointer movement order.
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

    /// Keeps the queue bounded while preserving protected input and lifecycle messages.
    private func trimPendingMessages() {
        while pendingMessages.count > Self.maxPendingMessages {
            if removeFirstPendingMessage(where: { $0.priority.isReplaceable }) { continue }
            if removeFirstPendingMessage(where: { $0.priority == .pointerMove }) { continue }
            if removeFirstPendingMessage(where: { $0.priority == .contactMove }) { continue }
            break
        }

        while Self.contactSampleCount(in: pendingMessages) > Self.maxPendingContactSamples {
            if removeFirstPendingMessage(where: { $0.priority == .contactMove }) { continue }
            break
        }
    }

    /// Counts batched contact-move samples currently waiting in the scheduler.
    private static func contactSampleCount(in pendingMessages: [PendingMessage]) -> Int {
        pendingMessages.reduce(into: 0) { result, pending in
            guard case .contactMove = pending.priority,
                  let inputMessage = try? InputEventMessage.deserializePayload(pending.message.payload),
                  case let .pointerSampleBatch(batch) = inputMessage.event else {
                return
            }
            result += batch.samples.count
        }
    }

    /// Removes the oldest pending message matching `shouldRemove`.
    private func removeFirstPendingMessage(where shouldRemove: (PendingMessage) -> Bool) -> Bool {
        guard let index = pendingMessages.firstIndex(where: shouldRemove) else { return false }
        pendingMessages.remove(at: index)
        return true
    }

    /// Drops delayed replaceable input that is older than a packet already handled for the stream.
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

    /// Classifies a control message for input coalescing and backlog trimming.
    private static func classification(for message: ControlMessage) -> (streamID: StreamID?, priority: Priority) {
        guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload) else {
            return (nil, .protected)
        }

        switch inputMessage.event {
        case .mouseMoved:
            return (inputMessage.streamID, .pointerMove)
        case .mouseDragged:
            return (inputMessage.streamID, .pointerMove)
        case .rightMouseDragged:
            return (inputMessage.streamID, .pointerMove)
        case .otherMouseDragged:
            return (inputMessage.streamID, .pointerMove)
        case let .scrollWheel(event):
            return (inputMessage.streamID, event.isBoundaryScrollEvent ? .protected : .replaceable(.scrollWheel))
        case let .pointerSampleBatch(batch):
            if batch.phase == .hover {
                return (inputMessage.streamID, .pointerMove)
            }
            if batch.phase == .moved {
                return (inputMessage.streamID, .contactMove)
            }
            return (inputMessage.streamID, .protected)
        default:
            return (inputMessage.streamID, .protected)
        }
    }

    /// Returns whether the message carries native scroll metadata that must be merged conservatively.
    private static func hasNativeScrollMetadata(_ message: ControlMessage) -> Bool {
        guard let inputMessage = try? InputEventMessage.deserializePayload(message.payload),
              case let .scrollWheel(event) = inputMessage.event else {
            return false
        }
        return event.hasNativeScrollMetadata
    }

    /// Merges adjacent native continuous scroll packets when their metadata is compatible.
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
#endif
