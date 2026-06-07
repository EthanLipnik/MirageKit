//
//  MirageRenderFrame.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Stream-local frame snapshot for decode-to-render handoff.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

package struct MirageRenderFrame: @unchecked Sendable {
    package let pixelBuffer: CVPixelBuffer
    package let contentRect: CGRect
    package let presentationMetadata: MirageRenderFramePresentationMetadata
    package let cursor: MirageRenderCursor
    package let decodeTime: CFAbsoluteTime
    package let presentationTime: CMTime
    package let remotePresentationTime: CMTime
    package let hostEpoch: UInt16?
    package let dimensionToken: UInt16?
    package let frameNumber: UInt32?
    package let queueEpoch: UInt64?
    package let transportPathKind: MirageCore.MirageNetworkPathKind
    package let targetPlayoutTime: CFAbsoluteTime?
    package let targetPlayoutDelayMs: Double
    package var timeline: MirageDiagnostics.FrameTimeline?

    package var sequence: UInt64 {
        cursor.sequence
    }

    package init(
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
        transportPathKind: MirageCore.MirageNetworkPathKind = .unknown,
        targetPlayoutTime: CFAbsoluteTime? = nil,
        targetPlayoutDelayMs: Double = 0,
        timeline: MirageDiagnostics.FrameTimeline? = nil
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
        self.transportPathKind = transportPathKind
        self.targetPlayoutTime = targetPlayoutTime
        self.targetPlayoutDelayMs = max(0, targetPlayoutDelayMs)
        self.timeline = timeline
    }

    package func withPlayoutMetadata(
        transportPathKind: MirageCore.MirageNetworkPathKind,
        targetPlayoutTime: CFAbsoluteTime?,
        targetPlayoutDelayMs: Double
    ) -> MirageRenderFrame {
        MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            sequence: cursor.sequence,
            generation: cursor.generation,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            remotePresentationTime: remotePresentationTime,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            frameNumber: frameNumber,
            queueEpoch: queueEpoch,
            transportPathKind: transportPathKind,
            targetPlayoutTime: targetPlayoutTime,
            targetPlayoutDelayMs: targetPlayoutDelayMs,
            timeline: timeline
        )
    }
}
