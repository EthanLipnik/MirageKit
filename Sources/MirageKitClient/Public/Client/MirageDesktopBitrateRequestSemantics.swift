//
//  MirageDesktopBitrateRequestSemantics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//
//  Desktop bitrate request semantics helpers.
//

import CoreGraphics
import Foundation

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
        let geometryScaleFactor = desktopGeometryScaleFactor(for: displayResolution)
        guard let enteredBitrateBps, enteredBitrateBps > 0 else {
            return MirageDesktopBitrateRequestSemantics(
                enteredBitrateBps: nil,
                requestedTargetBitrateBps: requestedTargetBitrateBps,
                bitrateAdaptationCeilingBps: bitrateAdaptationCeilingBps,
                geometryScaleFactor: geometryScaleFactor
            )
        }

        let scaledRequestedTargetBitrate = Int((Double(enteredBitrateBps) * geometryScaleFactor).rounded(.down))
        let scaledBitrateAdaptationCeiling = bitrateAdaptationCeilingBps.map {
            Int((Double($0) * geometryScaleFactor).rounded(.down))
        }

        return MirageDesktopBitrateRequestSemantics(
            enteredBitrateBps: enteredBitrateBps,
            requestedTargetBitrateBps: max(1, scaledRequestedTargetBitrate),
            bitrateAdaptationCeilingBps: scaledBitrateAdaptationCeiling.map { max(1, $0) },
            geometryScaleFactor: geometryScaleFactor
        )
    }

    private static func desktopGeometryScaleFactor(for displayResolution: CGSize) -> Double {
        guard displayResolution.width > 0, displayResolution.height > 0 else { return 1.0 }
        let baselinePixels = 2560.0 * 1440.0
        let displayPixels = Double(displayResolution.width) * Double(displayResolution.height)
        return min(max(displayPixels / baselinePixels, 1.0), 2.0)
    }
}
