//
//  MirageClientService+MessageHandling+Cursor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Cursor control message handling.
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

@MainActor
extension MirageClientService {
    /// Applies a host cursor-shape update and notifies stream views when presentation changes.
    func handleCursorUpdate(_ message: MirageWire.ControlMessage) {
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let update: MirageWire.CursorUpdateMessage
        do {
            update = try message.decode(MirageWire.CursorUpdateMessage.self)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode cursor update: ")
            return
        }
        let decodeMilliseconds = MirageCursorLatencyProbe.elapsedMilliseconds(since: decodeStart)
        recordCursorControlReceiveSample(updateReceived: true, positionReceived: false)
        let storeStart = CFAbsoluteTimeGetCurrent()
        let didChange = cursorStore.updateCursor(
            streamID: update.streamID,
            cursorType: update.cursorType,
            isVisible: update.isVisible
        )
        let storeMilliseconds = MirageCursorLatencyProbe.elapsedMilliseconds(since: storeStart)
        MirageCursorLatencyProbe.clientControlReceive(
            kind: "shape",
            streamID: update.streamID,
            didChange: didChange,
            decodeMilliseconds: decodeMilliseconds,
            storeMilliseconds: storeMilliseconds
        )
        if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
        onCursorUpdate?(update.streamID, update.cursorType, update.isVisible)
    }

    /// Applies a host cursor-position update to the per-stream normalized cursor store.
    func handleCursorPositionUpdate(_ message: MirageWire.ControlMessage) {
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let update: MirageWire.CursorPositionUpdateMessage
        do {
            update = try message.decode(MirageWire.CursorPositionUpdateMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode cursor position update: "
            )
            return
        }
        let decodeMilliseconds = MirageCursorLatencyProbe.elapsedMilliseconds(since: decodeStart)
        recordCursorControlReceiveSample(updateReceived: false, positionReceived: true)
        let position = CGPoint(x: CGFloat(update.normalizedX), y: CGFloat(update.normalizedY))
        let storeStart = CFAbsoluteTimeGetCurrent()
        let didChange = cursorPositionStore.updatePosition(
            streamID: update.streamID,
            position: position,
            isVisible: update.isVisible
        )
        let storeMilliseconds = MirageCursorLatencyProbe.elapsedMilliseconds(since: storeStart)
        MirageCursorLatencyProbe.clientControlReceive(
            kind: "position",
            streamID: update.streamID,
            didChange: didChange,
            decodeMilliseconds: decodeMilliseconds,
            storeMilliseconds: storeMilliseconds
        )
        if didChange { MirageCursorUpdateRouter.shared.notify(streamID: update.streamID) }
    }

    /// Records throttled cursor-control message counts for steady-state diagnostics.
    private func recordCursorControlReceiveSample(updateReceived: Bool, positionReceived: Bool) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        if updateReceived { cursorUpdateMessagesSinceLastSample &+= 1 }
        if positionReceived { cursorPositionMessagesSinceLastSample &+= 1 }

        let now = CFAbsoluteTimeGetCurrent()
        if lastCursorControlSampleTime == 0 {
            lastCursorControlSampleTime = now
            return
        }
        guard now - lastCursorControlSampleTime >= cursorControlSampleInterval else { return }

        let updateCount = cursorUpdateMessagesSinceLastSample
        let positionCount = cursorPositionMessagesSinceLastSample
        cursorUpdateMessagesSinceLastSample = 0
        cursorPositionMessagesSinceLastSample = 0
        lastCursorControlSampleTime = now
        guard updateCount > 0 || positionCount > 0 else { return }

        MirageLogger.network(
            "Cursor control sample (1s): cursorUpdates=\(updateCount), cursorPositions=\(positionCount)"
        )
    }
}
