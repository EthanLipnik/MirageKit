//
//  StreamContext+MediaSendProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
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
#if os(macOS)
extension StreamContext {
    func setMediaSendProfile(
        _ profile: MirageMedia.MirageMediaSendProfile,
        diagnosticsProvider:
        (@Sendable (MirageMedia.MirageMediaSendProfile) async -> MirageQueuedUnreliableSendDiagnostics?)? = nil
    ) -> Locked<MirageMedia.MirageMediaSendProfile> {
        let reference: Locked<MirageMedia.MirageMediaSendProfile>
        if let mediaSendProfileReference {
            reference = mediaSendProfileReference
            reference.withLock { $0 = profile }
        } else {
            reference = Locked(profile)
            mediaSendProfileReference = reference
        }
        let limits = profile.queuedUnreliableRecommendedLimits
        mediaSendProfile = profile
        mediaSendProfileRawValue = profile.rawValue
        mediaSendProfileMaxOutstandingPackets = limits.maxOutstandingPackets
        mediaSendProfileMaxOutstandingBytes = limits.maxOutstandingBytes
        mediaSendProfileMaxQueuedPackets = limits.maxQueuedPackets
        mediaSendDiagnosticsProvider = diagnosticsProvider
        return reference
    }

    func activeMediaSendProfile() -> MirageMedia.MirageMediaSendProfile {
        if let mediaSendProfileReference {
            return mediaSendProfileReference.read { $0 }
        }
        return mediaSendProfile ?? .interactiveMedia
    }
}
#endif
