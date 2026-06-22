//
//  SharedVirtualDisplayManager+Geometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
#if os(macOS)
import CoreGraphics

extension SharedVirtualDisplayManager {
    /// Returns true when the observed display size differs from the requested size beyond CoreGraphics rounding tolerance.
    func needsResize(currentResolution: CGSize, targetResolution: CGSize) -> Bool {
        let widthDiff = abs(currentResolution.width - targetResolution.width)
        let heightDiff = abs(currentResolution.height - targetResolution.height)
        return widthDiff > 2 || heightDiff > 2
    }
}
#endif
