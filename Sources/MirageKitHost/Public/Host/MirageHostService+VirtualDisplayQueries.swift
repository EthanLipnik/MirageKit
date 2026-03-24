//
//  MirageHostService+VirtualDisplayQueries.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display query helpers.
//

import Foundation
import MirageKit
import CoreGraphics

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Check if a window's stream uses a dedicated virtual display.
    func isStreamUsingVirtualDisplay(windowID: WindowID) -> Bool {
        windowVirtualDisplayStateByWindowID[windowID] != nil
    }

    func isStreamUsingVirtualDisplay(streamID: StreamID) -> Bool {
        windowVirtualDisplayStateByWindowID.values.contains { $0.streamID == streamID }
    }

    /// Get dedicated virtual display state for a window's stream.
    internal func getVirtualDisplayState(windowID: WindowID) -> WindowVirtualDisplayState? {
        windowVirtualDisplayStateByWindowID[windowID]
    }

    /// Get dedicated virtual display state by stream ID.
    internal func getVirtualDisplayState(streamID: StreamID) -> WindowVirtualDisplayState? {
        windowVirtualDisplayStateByWindowID.values.first { $0.streamID == streamID }
    }

    /// Cache dedicated virtual display state for a stream window.
    internal func setVirtualDisplayState(windowID: WindowID, state: WindowVirtualDisplayState) {
        windowVirtualDisplayStateByWindowID[windowID] = state
    }

    /// Clear dedicated virtual display state for a stream window.
    func clearVirtualDisplayState(windowID: WindowID) {
        windowVirtualDisplayStateByWindowID.removeValue(forKey: windowID)
    }

    /// Get dedicated virtual display visible bounds for a window's stream.
    func getVirtualDisplayBounds(windowID: WindowID) -> CGRect? {
        windowVirtualDisplayStateByWindowID[windowID]?.bounds
    }

    func currentVirtualDisplayScaleFactor(windowID: WindowID) -> CGFloat {
        if let state = windowVirtualDisplayStateByWindowID[windowID] {
            return max(1.0, state.scaleFactor)
        }
        return max(1.0, sharedVirtualDisplayScaleFactor)
    }

    func clientVirtualDisplayScaleFactor(streamID: StreamID) -> CGFloat? {
        guard let state = getVirtualDisplayState(streamID: streamID) else { return nil }
        return max(1.0, state.clientScaleFactor)
    }

    /// Update the cached window frame for input coordinate translation.
    func updateInputCacheFrame(windowID: WindowID, newFrame: CGRect) {
        if let streamID = inputStreamCacheActor.getStreamID(forWindowID: windowID) {
            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
            MirageLogger.host("Updated input cache frame for window \(windowID): \(newFrame)")
        }
    }

    /// Bring a window to the front using SkyLight APIs.
    @discardableResult
    static func bringWindowToFront(_ windowID: WindowID) -> Bool {
        #if os(macOS)
        return CGSWindowSpaceBridge.bringWindowToFront(windowID)
        #else
        return false
        #endif
    }
}
#endif
