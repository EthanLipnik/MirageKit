//
//  MirageHostWindowController+Frames.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

extension MirageHostWindowController {
    /// Returns the current CGWindowList frame for a window ID.
    ///
    /// Cached values are returned immediately and refreshed asynchronously so
    /// callers avoid blocking on repeated `CGWindowListCopyWindowInfo` calls.
    func currentWindowFrame(for windowID: WindowID) -> CGRect? {
        if let cachedFrame = cachedWindowFrames[windowID] {
            refreshWindowFrameCache(for: windowID)
            return cachedFrame
        }
        let freshFrame = Self.fetchWindowFrameSnapshot(for: windowID)
        if let freshFrame {
            cachedWindowFrames[windowID] = freshFrame
        }
        return freshFrame
    }

    /// Refreshes the cached CGWindow frame for a window ID off the main actor.
    func refreshWindowFrameCache(for windowID: WindowID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let frame = await Self.fetchWindowFrameSnapshotAsync(for: windowID)
            if let frame {
                cachedWindowFrames[windowID] = frame
            } else {
                cachedWindowFrames.removeValue(forKey: windowID)
            }
        }
    }

    /// Reads a one-window frame snapshot from CoreGraphics.
    nonisolated static func fetchWindowFrameSnapshot(for windowID: WindowID) -> CGRect? {
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let windowInfo = windowList.first,
           let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"],
           let w = bounds["Width"], let h = bounds["Height"] {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Reads a CoreGraphics frame snapshot from a detached utility task.
    nonisolated static func fetchWindowFrameSnapshotAsync(for windowID: WindowID) async -> CGRect? {
        await Task.detached(priority: .utility) {
            fetchWindowFrameSnapshot(for: windowID)
        }.value
    }

    /// Returns the AX frame for a window element if available.
    func axWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        HostAccessibilityWindowLookup.frame(of: axWindow)
    }
}
#endif
