//
//  MirageRenderFrame.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Stream-local frame snapshot for decode-to-render handoff.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

struct MirageRenderCursor: Sendable, Equatable, Hashable {
    static let zero = MirageRenderCursor(generation: 0, sequence: 0)

    let generation: UInt64
    let sequence: UInt64

    var hasSubmittedFrame: Bool {
        sequence > 0
    }

    func isAfter(_ other: MirageRenderCursor) -> Bool {
        if generation != other.generation {
            return generation > other.generation
        }
        return sequence > other.sequence
    }
}

struct MirageRenderFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
    let cursor: MirageRenderCursor
    var sequence: UInt64 { cursor.sequence }
    let decodeTime: CFAbsoluteTime
    let presentationTime: CMTime
    let remotePresentationTime: CMTime
    let hostEpoch: UInt16?
    let dimensionToken: UInt16?
    let frameNumber: UInt32?
    let queueEpoch: UInt64?
}
