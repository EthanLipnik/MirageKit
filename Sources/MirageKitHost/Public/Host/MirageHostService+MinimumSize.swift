//
//  MirageHostService+MinimumSize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream minimum size tracking.
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
    /// Records a host-observed minimum content size for a streamed window.
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

    /// Resolves the minimum size to enforce before streaming a window.
    func resolvedMinimumSize(for window: MirageMedia.MirageWindow) async -> CGSize {
        if let minSize = minimumSizesByWindowID[window.id] { return minSize }
        if let discovered = await windowController.discoverMinimumSize(for: window) {
            return discovered
        }

        let fallbackMin = fallbackMinimumSize(for: window.frame)
        return CGSize(width: CGFloat(fallbackMin.minWidth), height: CGFloat(fallbackMin.minHeight))
    }
}
#endif
