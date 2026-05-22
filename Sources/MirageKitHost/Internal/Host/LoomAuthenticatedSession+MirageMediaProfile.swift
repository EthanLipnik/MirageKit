//
//  LoomAuthenticatedSession+MirageMediaProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Loom

#if os(macOS)
extension LoomAuthenticatedSession {
    func mirageMediaSendProfile() async -> LoomQueuedUnreliableSendProfile {
        guard pathSnapshot?.interfaceNames.contains(where: { interfaceName in
            interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("awdl")
        }) == true else {
            return .interactiveMedia
        }
        return .proximityInteractiveMedia
    }
}
#endif
