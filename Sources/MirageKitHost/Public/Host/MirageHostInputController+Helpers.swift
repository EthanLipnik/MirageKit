//
//  MirageHostInputController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
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

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Helpers

    /// Posts an event to the session event tap.
    func postEvent(_ event: CGEvent) {
        postEvent(event, domain: .session)
    }

    /// Posts an event to the requested host injection domain.
    func postEvent(_ event: CGEvent, domain: HostKeyboardInjectionDomain) {
        switch domain {
        case .session:
            MirageInjectedEventTag.postSession(event)
        case .hid:
            MirageInjectedEventTag.postHID(event)
        }
    }

    /// Posts a synthetic flags-changed event for the requested modifier state.
    func postFlagsChangedEvent(_ modifiers: MirageInput.MirageModifierFlags, domain: HostKeyboardInjectionDomain) {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return
        }
        cgEvent.type = .flagsChanged
        cgEvent.flags = modifiers.cgEventFlags
        postEvent(cgEvent, domain: domain)
    }

    /// Returns the current CoreGraphics window frame for a host window ID.
    func currentWindowFrame(for windowID: WindowID) -> CGRect? {
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let windowInfo = windowList.first,
           let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"],
           let w = bounds["Width"], let h = bounds["Height"] {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Resolves the input target frame, preferring recent OS-reported geometry when available.
    func resolvedInputWindowFrame(for windowID: WindowID, streamFrame: CGRect) -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()

        if let cached = inputWindowFrameCacheByWindowID[windowID] {
            let cacheFresh = now - cached.sampledAt < inputWindowFrameRefreshInterval
            let streamFrameStable = framesAreClose(
                cached.streamFrame,
                streamFrame,
                tolerance: inputWindowFrameSourceTolerance
            )
            if cacheFresh, streamFrameStable {
                return cached.resolvedFrame
            }
        }

        let sampledFrame = currentWindowFrame(for: windowID)
        let resolvedFrame = sampledFrame ?? streamFrame
        inputWindowFrameCacheByWindowID[windowID] = CachedInputWindowFrame(
            streamFrame: streamFrame,
            resolvedFrame: resolvedFrame,
            sampledAt: now
        )
        pruneInputWindowFrameCache(now: now)
        return resolvedFrame
    }

    /// Removes stale input-frame cache entries.
    func pruneInputWindowFrameCache(now: CFAbsoluteTime) {
        guard !inputWindowFrameCacheByWindowID.isEmpty else { return }
        inputWindowFrameCacheByWindowID = inputWindowFrameCacheByWindowID.filter {
            now - $0.value.sampledAt <= inputWindowFrameCacheTTL
        }
    }

    /// Returns whether two frames are close enough to be treated as equivalent.
    func framesAreClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
            abs(a.origin.y - b.origin.y) <= tolerance &&
            abs(a.width - b.width) <= tolerance &&
            abs(a.height - b.height) <= tolerance
    }
}
#endif
