//
//  WindowFiltering.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/5/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)

/// Metadata read from `CGWindowList` for visibility and stacking decisions.
struct WindowListMetadata {
    /// Window alpha reported by CoreGraphics.
    let alpha: CGFloat
    /// Whether CoreGraphics currently reports the window as onscreen.
    let isOnScreen: Bool
    /// Position in the `CGWindowList` result, where lower values are visually earlier in the list.
    let orderIndex: Int
}

/// Fetches the current window frame from CGWindowList for a specific window ID.
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

/// Fetches extended window metadata from CGWindowList for visibility filtering.
func fetchWindowMetadata() -> [CGWindowID: WindowListMetadata] {
    guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }

    var metadata: [CGWindowID: WindowListMetadata] = [:]
    for (orderIndex, info) in windowList.enumerated() {
        guard let windowID = info[kCGWindowNumber as String] as? Int else { continue }
        let alpha = (info[kCGWindowAlpha as String] as? CGFloat) ?? 1.0
        let isOnScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        metadata[CGWindowID(windowID)] = WindowListMetadata(
            alpha: alpha,
            isOnScreen: isOnScreen,
            orderIndex: orderIndex
        )
    }
    return metadata
}

/// Returns whether two frames are nearly identical for tab detection.
func framesAreNearlyIdentical(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
    abs(a.origin.x - b.origin.x) < tolerance &&
        abs(a.origin.y - b.origin.y) < tolerance &&
        abs(a.width - b.width) < tolerance &&
        abs(a.height - b.height) < tolerance
}

/// Collapses tabbed windows and filters by visibility.
func detectAndCollapseTabGroups(
    _ windows: [MirageWindow],
    metadata: [CGWindowID: WindowListMetadata]
)
-> [MirageWindow] {
    var windowsByApp: [Int32: [MirageWindow]] = [:]
    for window in windows {
        guard let app = window.application else { continue }
        windowsByApp[app.id, default: []].append(window)
    }

    var collapsedWindows: [MirageWindow] = []

    for (_, appWindows) in windowsByApp {
        if appWindows.count == 1, let appWindow = appWindows.first {
            collapsedWindows.append(appWindow)
            continue
        }

        var processed = Set<WindowID>()

        for window in appWindows {
            if processed.contains(window.id) { continue }

            let similarFrameWindows = appWindows.filter { other in
                guard other.id != window.id,
                      !processed.contains(other.id) else {
                    return false
                }
                return framesAreNearlyIdentical(window.frame, other.frame)
            }

            if similarFrameWindows.isEmpty { collapsedWindows.append(window) } else {
                let allInGroup = [window] + similarFrameWindows
                let tabCount = allInGroup.count

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
            result.append(contentsOf: onScreenWindows)
        } else {
            if let first = appWindows.first { result.append(first) }
        }
    }

    return result
}

/// Computes fallback minimum window size based on current frame.
func fallbackMinimumSize(for frame: CGRect) -> (minWidth: Int, minHeight: Int) {
    let minWidth = max(200, Int(frame.width / 2))
    let minHeight = max(150, Int(frame.height / 2))
    return (minWidth, minHeight)
}

#endif
