//
//  MirageCursorLatencyProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/24/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

package enum MirageCursorLatencyProbe {
    package static var isEnabled: Bool {
        MirageLogger.isEnabled(.timing)
    }

    package static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        max(0, (CFAbsoluteTimeGetCurrent() - start) * 1_000)
    }

    package static func hostCursorSample(
        streamID: StreamID,
        cursorType: MirageWire.MirageCursorType,
        isVisible: Bool,
        didChange: Bool,
        source: String,
        sampleMilliseconds: Double
    ) {
        emit(
            "Cursor.HostSample",
            "stream=\(streamID) type=\(cursorType) visible=\(isVisible) changed=\(didChange) source=\(source) sampleMs=\(format(sampleMilliseconds))"
        )
    }

    package static func hostControlSend(
        kind: String,
        streamID: StreamID,
        sent: Bool,
        sampleToSendMilliseconds: Double?,
        sendMilliseconds: Double
    ) {
        let sampleToSend = sampleToSendMilliseconds.map { format($0) } ?? "n/a"
        emit(
            "Cursor.ControlSend",
            "kind=\(kind) stream=\(streamID) sent=\(sent) sampleToSendMs=\(sampleToSend) sendMs=\(format(sendMilliseconds))"
        )
    }

    package static func clientControlReceive(
        kind: String,
        streamID: StreamID,
        didChange: Bool,
        decodeMilliseconds: Double,
        storeMilliseconds: Double
    ) {
        emit(
            "Cursor.ClientReceive",
            "kind=\(kind) stream=\(streamID) changed=\(didChange) decodeMs=\(format(decodeMilliseconds)) storeMs=\(format(storeMilliseconds))"
        )
    }

    package static func routerFlush(
        refreshCount: Int,
        forcedCount: Int,
        flushMilliseconds: Double
    ) {
        emit(
            "Cursor.RouterFlush",
            "refreshes=\(refreshCount) forced=\(forcedCount) flushMs=\(format(flushMilliseconds))"
        )
    }

    package static func updateCursorImage(
        streamID: StreamID?,
        cursorType: MirageWire.MirageCursorType,
        durationMilliseconds: Double
    ) {
        let streamDescription = streamID.map(String.init) ?? "none"
        emit(
            "Cursor.UpdateImage",
            "stream=\(streamDescription) type=\(cursorType) durationMs=\(format(durationMilliseconds))"
        )
    }

    package static func pointerInteractionInvalidate(
        reason: String,
        streamID: StreamID?,
        cursorType: MirageWire.MirageCursorType,
        durationMilliseconds: Double
    ) {
        let streamDescription = streamID.map(String.init) ?? "none"
        emit(
            "Cursor.PointerInvalidate",
            "reason=\(reason) stream=\(streamDescription) type=\(cursorType) durationMs=\(format(durationMilliseconds))"
        )
    }

    private static func emit(_ name: StaticString, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        MirageLogger.signpostEvent(.timing, name, message())
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
