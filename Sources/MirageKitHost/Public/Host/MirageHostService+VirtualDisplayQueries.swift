//
//  MirageHostService+VirtualDisplayQueries.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display query helpers.
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

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Returns whether a window stream is backed by a dedicated virtual display.
    func isStreamUsingVirtualDisplay(windowID: WindowID) -> Bool {
        windowVirtualDisplayStateByWindowID[windowID] != nil
    }

    /// Returns whether a stream is backed by a dedicated virtual display.
    func isStreamUsingVirtualDisplay(streamID: StreamID) -> Bool {
        windowVirtualDisplayStateByWindowID.values.contains { $0.streamID == streamID }
    }
}

extension MirageHostService {
    /// Returns the dedicated virtual display state for a window stream.
    func virtualDisplayState(windowID: WindowID) -> WindowVirtualDisplayState? {
        windowVirtualDisplayStateByWindowID[windowID]
    }

    /// Returns the dedicated virtual display state for a stream.
    func virtualDisplayState(streamID: StreamID) -> WindowVirtualDisplayState? {
        windowVirtualDisplayStateByWindowID.values.first { $0.streamID == streamID }
    }

    /// Stores dedicated virtual display state for a stream window.
    func setVirtualDisplayState(windowID: WindowID, state: WindowVirtualDisplayState) {
        windowVirtualDisplayStateByWindowID[windowID] = state
    }
}

public extension MirageHostService {
    /// Clears dedicated virtual display state for a stream window.
    func clearVirtualDisplayState(windowID: WindowID) {
        windowVirtualDisplayStateByWindowID.removeValue(forKey: windowID)
    }

    /// Returns the dedicated virtual display visible bounds for a window stream.
    func virtualDisplayBounds(windowID: WindowID) -> CGRect? {
        windowVirtualDisplayStateByWindowID[windowID]?.bounds
    }

    /// Returns the client scale factor negotiated for a dedicated virtual display stream.
    func clientVirtualDisplayScaleFactor(streamID: StreamID) -> CGFloat? {
        guard let state = virtualDisplayState(streamID: streamID) else { return nil }
        return max(1.0, state.clientScaleFactor)
    }

    /// Updates the cached window frame for input coordinate translation.
    func updateInputCacheFrame(windowID: WindowID, newFrame: CGRect) {
        if let streamID = inputStreamCache.streamID(forWindowID: windowID) {
            inputStreamCache.updateWindowFrame(streamID, newFrame: newFrame)
            MirageLogger.host("Updated input cache frame for window \(windowID): \(newFrame)")
        }
    }

    /// Attempts to bring a window forward when the caller does not need the SkyLight result.
    static func bringWindowToFrontIfPossible(_ windowID: WindowID) {
        #if os(macOS)
        CGSWindowSpaceBridge.bringWindowToFrontIfPossible(windowID)
        #endif
    }
}
#endif
