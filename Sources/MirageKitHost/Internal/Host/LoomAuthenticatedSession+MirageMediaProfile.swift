//
//  LoomAuthenticatedSession+MirageMediaProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Loom
import MirageKit

#if os(macOS)
extension LoomAuthenticatedSession {
    func mirageMediaSendProfile() async -> LoomQueuedUnreliableSendProfile {
        guard let pathSnapshot else {
            return .interactiveMedia
        }
        let mediaProfile = MirageNetworkPathClassifier.classify(pathSnapshot).mediaProfile
        return mediaProfile == .awdlRadio || mediaProfile == .proximityWiredLike
            ? .proximityInteractiveMedia
            : .interactiveMedia
    }
}
#endif
