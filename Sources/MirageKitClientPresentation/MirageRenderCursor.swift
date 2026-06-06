import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
//
//  MirageRenderCursor.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Stream-local submitted-frame cursor used by client presentation selection.
package struct MirageRenderCursor: Sendable, Equatable, Hashable {
    package static let zero = MirageRenderCursor(generation: 0, sequence: 0)

    package let generation: UInt64
    package let sequence: UInt64

    package init(generation: UInt64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }

    package var hasSubmittedFrame: Bool {
        sequence > 0
    }

    package func isAfter(_ other: MirageRenderCursor) -> Bool {
        if generation != other.generation {
            return generation > other.generation
        }
        return sequence > other.sequence
    }
}
