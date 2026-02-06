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

#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Check if a window's stream uses the shared virtual display.
    func isStreamUsingVirtualDisplay(windowID: WindowID) -> Bool {
        windowsUsingVirtualDisplay.contains(windowID)
    }

    /// Get the shared virtual display bounds for a window's stream.
    func getVirtualDisplayBounds(windowID: WindowID) -> CGRect? {
        guard windowsUsingVirtualDisplay.contains(windowID) else { return nil }
        return sharedVirtualDisplayBounds
    }

    /// Update the cached window frame for input coordinate translation.
    func updateInputCacheFrame(windowID: WindowID, newFrame: CGRect) {
        if let streamID = inputStreamCacheActor.getStreamID(forWindowID: windowID) {
            inputStreamCacheActor.updateWindowFrame(streamID, newFrame: newFrame)
            MirageLogger.host("Updated input cache frame for window \(windowID): \(newFrame)")
        }
    }

    /// Bring a window to the front using SkyLight APIs.
    static func bringWindowToFront(_ windowID: WindowID) -> Bool {
        #if os(macOS)
        return CGSWindowSpaceBridge.bringWindowToFront(windowID)
        #else
        return false
        #endif
    }
}
#endif
