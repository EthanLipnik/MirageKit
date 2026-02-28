//
//  InputOwnershipGate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation
import MirageKit

#if os(macOS)
actor InputOwnershipGate {
    nonisolated static let debounceWindow: CFAbsoluteTime = 0.120
    nonisolated static let ownershipHoldWindow: CFAbsoluteTime = 0.750

    private var activeStreamID: StreamID?
    private var lastSwitchAt: CFAbsoluteTime = 0
    private var ownershipHoldUntil: CFAbsoluteTime = 0

    nonisolated static func isOwnershipSwitchSignal(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .windowFocus,
             .mouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .keyDown:
            return true

        case .flagsChanged,
             .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .mouseUp,
             .rightMouseUp,
             .otherMouseUp,
             .scrollWheel,
             .magnify,
             .rotate,
             .windowResize,
             .relativeResize,
             .pixelResize,
             .keyUp:
            return false
        }
    }

    func considerSignal(
        streamID: StreamID,
        event: MirageInputEvent,
        hostKeyWindowEligible: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard hostKeyWindowEligible else { return false }
        guard Self.isOwnershipSwitchSignal(event) else { return false }

        if activeStreamID == streamID {
            ownershipHoldUntil = max(ownershipHoldUntil, now + Self.ownershipHoldWindow)
            return false
        }

        guard now >= ownershipHoldUntil else { return false }

        if lastSwitchAt > 0,
           now - lastSwitchAt < Self.debounceWindow {
            return false
        }

        activeStreamID = streamID
        lastSwitchAt = now
        ownershipHoldUntil = now + Self.ownershipHoldWindow
        return true
    }

    func forceOwnership(streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        activeStreamID = streamID
        lastSwitchAt = now
        ownershipHoldUntil = now + Self.ownershipHoldWindow
    }

    func clear(streamID: StreamID) {
        guard activeStreamID == streamID else { return }
        activeStreamID = nil
        lastSwitchAt = 0
        ownershipHoldUntil = 0
    }
}
#endif
