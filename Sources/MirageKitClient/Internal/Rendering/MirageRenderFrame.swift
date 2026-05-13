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

struct MirageRenderFramePresentationMetadata: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelFormat: OSType
    let contentReferenceSize: CGSize
    let normalizedContentRect: CGRect

    init(pixelBuffer: CVPixelBuffer, contentRect: CGRect) {
        pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let resolvedContentRect: CGRect
        if contentRect.width > 0, contentRect.height > 0 {
            resolvedContentRect = contentRect
        } else {
            resolvedContentRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        contentReferenceSize = resolvedContentRect.size

        guard width > 0, height > 0 else {
            normalizedContentRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        normalizedContentRect = CGRect(
            x: min(max(resolvedContentRect.origin.x / width, 0), 1),
            y: min(max(resolvedContentRect.origin.y / height, 0), 1),
            width: min(max(resolvedContentRect.size.width / width, 0), 1),
            height: min(max(resolvedContentRect.size.height / height, 0), 1)
        )
    }
}

struct MirageRenderFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
    let presentationMetadata: MirageRenderFramePresentationMetadata
    let cursor: MirageRenderCursor
    let decodeTime: CFAbsoluteTime
    let presentationTime: CMTime
    let remotePresentationTime: CMTime
    let hostEpoch: UInt16?
    let dimensionToken: UInt16?
    let frameNumber: UInt32?
    let queueEpoch: UInt64?
    var timeline: FrameTimeline?

    var sequence: UInt64 {
        cursor.sequence
    }

    init(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        sequence: UInt64,
        generation: UInt64 = 0,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        remotePresentationTime: CMTime,
        hostEpoch: UInt16? = nil,
        dimensionToken: UInt16? = nil,
        frameNumber: UInt32? = nil,
        queueEpoch: UInt64? = nil,
        timeline: FrameTimeline? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.contentRect = contentRect
        self.presentationMetadata = MirageRenderFramePresentationMetadata(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect
        )
        self.cursor = MirageRenderCursor(generation: generation, sequence: sequence)
        self.decodeTime = decodeTime
        self.presentationTime = presentationTime
        self.remotePresentationTime = remotePresentationTime
        self.hostEpoch = hostEpoch
        self.dimensionToken = dimensionToken
        self.frameNumber = frameNumber
        self.queueEpoch = queueEpoch
        self.timeline = timeline
    }
}
