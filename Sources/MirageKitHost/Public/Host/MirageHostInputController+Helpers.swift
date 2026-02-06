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
        MirageInjectedEventTag.postSession(event)
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

    func framesAreClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
            abs(a.origin.y - b.origin.y) <= tolerance &&
            abs(a.width - b.width) <= tolerance &&
            abs(a.height - b.height) <= tolerance
    }
}
#endif
