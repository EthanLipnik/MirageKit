//
//  MirageClientService+OverlayControlSessionRace.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
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
import Foundation
import Loom

struct OverlayControlSessionRaceResult: Sendable {
    let attempt: MirageClientService.ControlSessionAttempt
    let session: LoomAuthenticatedSession
}

enum OverlayControlSessionCandidateOutcome: Sendable {
    case connected(index: Int, attempt: MirageClientService.ControlSessionAttempt, session: LoomAuthenticatedSession)
    case failed(
        index: Int,
        attempt: MirageClientService.ControlSessionAttempt,
        classification: MirageClientService.ControlSessionFailureClassification,
        reason: String
    )
    case suppressed(index: Int, attempt: MirageClientService.ControlSessionAttempt, reason: String)
    case cancelled(index: Int, attempt: MirageClientService.ControlSessionAttempt)
}
