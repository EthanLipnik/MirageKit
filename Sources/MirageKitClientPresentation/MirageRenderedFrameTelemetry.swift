//
//  MirageRenderedFrameTelemetry.swift
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

/// Client-side render selection telemetry for the most recent presentation decision.
package struct MirageRenderedFrameTelemetry: Equatable, Sendable {
    package let streamID: StreamID
    package let selectedCursor: MirageRenderCursor?
    package let selectedFrameNumber: UInt32?
    package let renderedCursor: MirageRenderCursor?
    package let renderedFrameNumber: UInt32?
    package let renderedFrameSubmittedTime: CFAbsoluteTime
    package let repeatedDisplayTicks: UInt64
    package let droppedForLatency: UInt64

    package init(
        streamID: StreamID,
        selectedCursor: MirageRenderCursor?,
        selectedFrameNumber: UInt32?,
        renderedCursor: MirageRenderCursor?,
        renderedFrameNumber: UInt32?,
        renderedFrameSubmittedTime: CFAbsoluteTime,
        repeatedDisplayTicks: UInt64,
        droppedForLatency: UInt64
    ) {
        self.streamID = streamID
        self.selectedCursor = selectedCursor
        self.selectedFrameNumber = selectedFrameNumber
        self.renderedCursor = renderedCursor
        self.renderedFrameNumber = renderedFrameNumber
        self.renderedFrameSubmittedTime = renderedFrameSubmittedTime
        self.repeatedDisplayTicks = repeatedDisplayTicks
        self.droppedForLatency = droppedForLatency
    }
}
