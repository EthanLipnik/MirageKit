//
//  MirageRenderModePolicy.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import Foundation

/// Shared render telemetry thresholds and frame pacing policy constants.
package enum MirageRenderModePolicy {
    package static let healthyDecodeRatio = 0.95
    package static let stressedDecodeRatio = 0.80
    package static let maximumSmoothestPlayoutDelayFrames = MirageMedia.MirageStreamCadenceTarget.maximumPlayoutDelayFrames

    package static func normalizedTargetFPS(_ fps: Int) -> Int {
        max(1, min(120, fps))
    }
}
