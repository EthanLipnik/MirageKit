//
//  MirageDesktopBitrateRequestSemantics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//
//  Desktop bitrate request semantics helpers.
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

package struct MirageDesktopBitrateRequestSemantics: Sendable, Equatable {
    package let enteredBitrateBps: Int?
    package let requestedTargetBitrateBps: Int?
    package let bitrateAdaptationCeilingBps: Int?
    package let geometryScaleFactor: Double

    package static func resolve(
        enteredBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        bitrateAdaptationCeilingBps: Int?,
        displayResolution: CGSize,
        scaleAutomaticTargetBitrate: Bool = true
    ) -> MirageDesktopBitrateRequestSemantics {
        let geometryScaleFactor: Double
        if displayResolution.width > 0, displayResolution.height > 0 {
            let baselinePixels = 2560.0 * 1440.0
            let displayPixels = Double(displayResolution.width) * Double(displayResolution.height)
            geometryScaleFactor = min(max(displayPixels / baselinePixels, 1.0), 2.0)
        } else {
            geometryScaleFactor = 1.0
        }
        guard let enteredBitrateBps, enteredBitrateBps > 0 else {
            let scaledTarget = scaledAutomaticBitrate(
                requestedTargetBitrateBps,
                ceilingBps: bitrateAdaptationCeilingBps,
                scale: scaleAutomaticTargetBitrate ? geometryScaleFactor : 1.0
            )
            return MirageDesktopBitrateRequestSemantics(
                enteredBitrateBps: nil,
                requestedTargetBitrateBps: scaledTarget,
                bitrateAdaptationCeilingBps: bitrateAdaptationCeilingBps,
                geometryScaleFactor: geometryScaleFactor
            )
        }

        return MirageDesktopBitrateRequestSemantics(
            enteredBitrateBps: enteredBitrateBps,
            requestedTargetBitrateBps: max(1, enteredBitrateBps),
            bitrateAdaptationCeilingBps: bitrateAdaptationCeilingBps.map { max(1, $0) },
            geometryScaleFactor: geometryScaleFactor
        )
    }

    private static func scaledAutomaticBitrate(
        _ bitrateBps: Int?,
        ceilingBps: Int?,
        scale: Double
    ) -> Int? {
        guard let bitrateBps, bitrateBps > 0 else { return nil }
        let scaled = max(
            1,
            Int((Double(bitrateBps) * max(1.0, scale)).rounded(.toNearestOrAwayFromZero))
        )
        guard let ceilingBps, ceilingBps > 0 else { return scaled }
        return min(max(1, ceilingBps), scaled)
    }
}
