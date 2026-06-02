//
//  MirageRenderedFrameTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import Foundation
import MirageKit

/// Client-side render selection telemetry for the most recent presentation decision.
struct MirageRenderedFrameTelemetry: Equatable, Sendable {
    let streamID: StreamID
    let selectedCursor: MirageRenderCursor?
    let selectedFrameNumber: UInt32?
    let renderedCursor: MirageRenderCursor?
    let renderedFrameNumber: UInt32?
    let renderedFrameSubmittedTime: CFAbsoluteTime
    let repeatedDisplayTicks: UInt64
    let droppedForLatency: UInt64
}
