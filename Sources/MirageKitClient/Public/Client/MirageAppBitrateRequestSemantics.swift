//
//  MirageAppBitrateRequestSemantics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//
//  App-atlas bitrate request semantics helpers.
//

package struct MirageAppBitrateRequestSemantics: Sendable, Equatable {
    package let enteredBitrateBps: Int?
    package let requestedTargetBitrateBps: Int?
    package let bitrateAdaptationCeilingBps: Int?

    package static func resolve(
        enteredBitrateBps: Int?,
        requestedTargetBitrateBps: Int?,
        bitrateAdaptationCeilingBps: Int?
    ) -> MirageAppBitrateRequestSemantics {
        guard let enteredBitrateBps, enteredBitrateBps > 0 else {
            return MirageAppBitrateRequestSemantics(
                enteredBitrateBps: nil,
                requestedTargetBitrateBps: requestedTargetBitrateBps,
                bitrateAdaptationCeilingBps: bitrateAdaptationCeilingBps.map { max(1, $0) }
            )
        }

        return MirageAppBitrateRequestSemantics(
            enteredBitrateBps: enteredBitrateBps,
            requestedTargetBitrateBps: max(1, enteredBitrateBps),
            bitrateAdaptationCeilingBps: bitrateAdaptationCeilingBps.map { max(1, $0) }
        )
    }
}
