//
//  MirageHostService+MinimumSize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream minimum size tracking.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
public extension MirageHostService {
    func updateMinimumSize(for windowID: WindowID, minSize: CGSize) {
        guard minSize.width > 0, minSize.height > 0 else { return }
        if let existing = minimumSizesByWindowID[windowID] {
            minimumSizesByWindowID[windowID] = CGSize(
                width: min(existing.width, minSize.width),
                height: min(existing.height, minSize.height)
            )
        } else {
            minimumSizesByWindowID[windowID] = minSize
        }
    }

    func resolvedMinimumSize(for window: MirageWindow) async -> CGSize {
        if let minSize = minimumSizesByWindowID[window.id] { return minSize }
        if let discovered = await windowController.discoverMinimumSize(for: window) {
            return discovered
        }

        let fallbackMin = fallbackMinimumSize(for: window.frame)
        return CGSize(width: CGFloat(fallbackMin.minWidth), height: CGFloat(fallbackMin.minHeight))
    }
}
#endif
