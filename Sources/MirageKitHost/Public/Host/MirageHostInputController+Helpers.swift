//
//  MirageHostInputController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Helpers

    func postEvent(_ event: CGEvent) {
        postEvent(event, domain: .session)
    }

    func postEvent(_ event: CGEvent, domain: HostKeyboardInjectionDomain) {
        switch domain {
        case .session:
            MirageInjectedEventTag.postSession(event)
        case .hid:
            MirageInjectedEventTag.postHID(event)
        }
    }

    func postFlagsChangedEvent(_ modifiers: MirageModifierFlags, domain: HostKeyboardInjectionDomain) {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return
        }
        cgEvent.type = .flagsChanged
        cgEvent.flags = modifiers.cgEventFlags
        postEvent(cgEvent, domain: domain)
    }

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

    func resolvedInputWindowFrame(for windowID: WindowID, streamFrame: CGRect) -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()

        if let cached = inputWindowFrameCacheByWindowID[windowID] {
            let cacheFresh = now - cached.sampledAt < inputWindowFrameRefreshInterval
            let streamFrameStable = framesAreClose(
                cached.streamFrame,
                streamFrame,
                tolerance: inputWindowFrameSourceTolerance
            )
            if cacheFresh && streamFrameStable {
                return cached.resolvedFrame
            }
        }

        let sampledFrame = currentWindowFrame(for: windowID)
        let shouldUseSampledFrame = sampledFrame.map { framesAreClose($0, streamFrame) } ?? false
        let resolvedFrame = shouldUseSampledFrame ? (sampledFrame ?? streamFrame) : streamFrame
        inputWindowFrameCacheByWindowID[windowID] = CachedInputWindowFrame(
            streamFrame: streamFrame,
            resolvedFrame: resolvedFrame,
            sampledAt: now
        )
        pruneInputWindowFrameCache(now: now)
        return resolvedFrame
    }

    func pruneInputWindowFrameCache(now: CFAbsoluteTime) {
        guard !inputWindowFrameCacheByWindowID.isEmpty else { return }
        inputWindowFrameCacheByWindowID = inputWindowFrameCacheByWindowID.filter {
            now - $0.value.sampledAt <= inputWindowFrameCacheTTL
        }
    }

    func framesAreClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
            abs(a.origin.y - b.origin.y) <= tolerance &&
            abs(a.width - b.width) <= tolerance &&
            abs(a.height - b.height) <= tolerance
    }
}
#endif
