//
//  MirageDesktopBitrateRequestSemantics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//
//  Desktop bitrate request semantics helpers.
//

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
        displayResolution: CGSize
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
            return MirageDesktopBitrateRequestSemantics(
                enteredBitrateBps: nil,
                requestedTargetBitrateBps: requestedTargetBitrateBps,
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
}
