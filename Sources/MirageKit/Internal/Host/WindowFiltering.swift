//
//  WindowFiltering.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit

/// Fetches the current window frame from CGWindowList for a specific window ID
func currentWindowFrame(for windowID: WindowID) -> CGRect? {
    if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
       let windowInfo = windowList.first,
       let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
       let windowX = bounds["X"],
       let windowY = bounds["Y"],
       let windowWidth = bounds["Width"],
       let windowHeight = bounds["Height"] {
        return CGRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
    }

    guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
          let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) }),
          let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
          let windowX = bounds["X"],
          let windowY = bounds["Y"],
          let windowWidth = bounds["Width"],
          let windowHeight = bounds["Height"] else {
        return nil
    }

    return CGRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
}

/// Fetches extended window metadata from CGWindowList for visibility filtering
func fetchWindowMetadata() -> [CGWindowID: (alpha: CGFloat, isOnScreen: Bool)] {
    guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return [:]
    }

    var metadata: [CGWindowID: (alpha: CGFloat, isOnScreen: Bool)] = [:]
    for info in windowList {
        guard let windowID = info[kCGWindowNumber as String] as? Int else { continue }
        let alpha = (info[kCGWindowAlpha as String] as? CGFloat) ?? 1.0
        let isOnScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        metadata[CGWindowID(windowID)] = (alpha, isOnScreen)
    }
    return metadata
}

/// Checks if two frames are nearly identical (used for tab detection)
func framesAreNearlyIdentical(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
    abs(a.origin.x - b.origin.x) < tolerance &&
    abs(a.origin.y - b.origin.y) < tolerance &&
    abs(a.width - b.width) < tolerance &&
    abs(a.height - b.height) < tolerance
}

/// Detects tabbed windows, collapses them, and filters by visibility
/// Native macOS tabs share the exact same frame since only one tab is visible at a time
func detectAndCollapseTabGroups(_ windows: [MirageWindow], metadata: [CGWindowID: (alpha: CGFloat, isOnScreen: Bool)]) -> [MirageWindow] {
    // Group windows by application
    var windowsByApp: [Int32: [MirageWindow]] = [:]
    for window in windows {
        guard let app = window.application else { continue }
        windowsByApp[app.id, default: []].append(window)
    }

    var collapsedWindows: [MirageWindow] = []

    // Phase 1: Collapse tab groups (windows with identical frames)
    for (_, appWindows) in windowsByApp {
        if appWindows.count == 1 {
            collapsedWindows.append(appWindows[0])
            continue
        }

        // Collapse overlapping frames (tabs share identical position)
        var processed = Set<WindowID>()

        for window in appWindows {
            if processed.contains(window.id) { continue }

            let similarFrameWindows = appWindows.filter { other in
                guard other.id != window.id,
                      !processed.contains(other.id) else { return false }
                return framesAreNearlyIdentical(window.frame, other.frame)
            }

            if similarFrameWindows.isEmpty {
                collapsedWindows.append(window)
            } else {
                let allInGroup = [window] + similarFrameWindows
                let tabCount = allInGroup.count

                // Pick the on-screen tab, or first one if none on screen
                let visibleTab = allInGroup.first { w in
                    metadata[CGWindowID(w.id)]?.isOnScreen ?? w.isOnScreen
                } ?? window

                collapsedWindows.append(visibleTab.withTabCount(tabCount))

                for tab in similarFrameWindows {
                    processed.insert(tab.id)
                }
            }

            processed.insert(window.id)
        }
    }

    // Phase 2: Filter by isOnScreen - for apps with multiple windows after collapse,
    // prefer on-screen windows. Keep off-screen only if it's the sole window (minimized).
    var finalWindowsByApp: [Int32: [MirageWindow]] = [:]
    for window in collapsedWindows {
        guard let app = window.application else { continue }
        finalWindowsByApp[app.id, default: []].append(window)
    }

    var result: [MirageWindow] = []

    for (_, appWindows) in finalWindowsByApp {
        let onScreenWindows = appWindows.filter { w in
            metadata[CGWindowID(w.id)]?.isOnScreen ?? w.isOnScreen
        }

        if !onScreenWindows.isEmpty {
            // App has visible windows - show only those
            result.append(contentsOf: onScreenWindows)
        } else {
            // No on-screen windows - show one (likely minimized)
            if let first = appWindows.first {
                result.append(first)
            }
        }
    }

    return result
}

/// Computes fallback minimum window size based on current frame
func fallbackMinimumSize(for frame: CGRect) -> (minWidth: Int, minHeight: Int) {
    let minWidth = max(200, Int(frame.width / 2))
    let minHeight = max(150, Int(frame.height / 2))
    return (minWidth, minHeight)
}

#endif
