//
//  StreamContext+MediaSendProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

import Loom
import MirageKit

#if os(macOS)
extension StreamContext {
    func setMediaSendProfile(
        _ profile: LoomQueuedUnreliableSendProfile,
        diagnosticsProvider:
        (@Sendable (LoomQueuedUnreliableSendProfile) async -> LoomQueuedUnreliableSendDiagnostics?)? = nil
    ) -> Locked<LoomQueuedUnreliableSendProfile> {
        let reference: Locked<LoomQueuedUnreliableSendProfile>
        if let mediaSendProfileReference {
            reference = mediaSendProfileReference
            reference.withLock { $0 = profile }
        } else {
            reference = Locked(profile)
            mediaSendProfileReference = reference
        }
        let limits = profile.recommendedLimits
        mediaSendProfile = profile
        mediaSendProfileRawValue = profile.rawValue
        mediaSendProfileMaxOutstandingPackets = limits.maxOutstandingPackets
        mediaSendProfileMaxOutstandingBytes = limits.maxOutstandingBytes
        mediaSendProfileMaxQueuedPackets = limits.maxQueuedPackets
        mediaSendDiagnosticsProvider = diagnosticsProvider
        return reference
    }

    func activeMediaSendProfile() -> LoomQueuedUnreliableSendProfile {
        if let mediaSendProfileReference {
            return mediaSendProfileReference.read { $0 }
        }
        return mediaSendProfile ?? .interactiveMedia
    }
}
#endif
