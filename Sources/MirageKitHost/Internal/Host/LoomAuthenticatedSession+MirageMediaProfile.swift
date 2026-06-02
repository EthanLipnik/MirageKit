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
    private static let independentUnreliableReceiveSemantics = "independent-reliable-unreliable"

    static func mirageMediaSendProfile(for mediaPathProfile: MirageMediaPathProfile) -> LoomQueuedUnreliableSendProfile {
        mirageMediaSendProfile(
            for: mediaPathProfile,
            transportReceiveSemantics: nil
        )
    }

    static func mirageMediaSendProfile(
        for mediaPathProfile: MirageMediaPathProfile,
        transportReceiveSemantics: String?
    ) -> LoomQueuedUnreliableSendProfile {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return .interactiveMedia }
        guard let transportReceiveSemantics else { return .proximityRealtimeDisplay }
        guard transportReceiveSemantics == Self.independentUnreliableReceiveSemantics else {
            return .proximityRealtimeDisplaySingleLane
        }
        return .proximityRealtimeDisplay
    }

    private static func miragePreferredMediaSendProfile(for mediaPathProfile: MirageMediaPathProfile) -> LoomQueuedUnreliableSendProfile {
        mediaPathProfile.usesAwdlRadioPolicy
            ? .proximityRealtimeDisplay
            : .interactiveMedia
    }

    func mirageMediaSendProfile(
        resolvedMediaPathProfile: MirageMediaPathProfile,
        streamID: StreamID,
        phase: String
    ) async -> LoomQueuedUnreliableSendProfile {
        let preferredProfile = Self.miragePreferredMediaSendProfile(for: resolvedMediaPathProfile)
        let transportDiagnostics = context?.transportDiagnostics
        let receiveSemantics = transportDiagnostics?.receiveSemantics
        let resolvedProfile = Self.mirageMediaSendProfile(
            for: resolvedMediaPathProfile,
            transportReceiveSemantics: receiveSemantics
        )
        if resolvedProfile != preferredProfile {
            let transport = transportDiagnostics?.selectedTransportKind.rawValue ?? "unknown"
            let semantics = receiveSemantics ?? "unknown"
            MirageLogger.host(
                "event=media_send_profile_downgrade phase=\(phase) stream=\(streamID) " +
                    "resolvedMediaPath=\(resolvedMediaPathProfile.rawValue) " +
                    "preferredProfile=\(preferredProfile.rawValue) " +
                    "selectedProfile=\(resolvedProfile.rawValue) " +
                    "transport=\(transport) receiveSemantics=\(semantics)"
            )
        }
        let liveProfile = await mirageMediaSendProfile()
        if liveProfile != resolvedProfile {
            MirageLogger.host(
                "event=media_send_profile_mismatch phase=\(phase) stream=\(streamID) " +
                    "resolvedMediaPath=\(resolvedMediaPathProfile.rawValue) " +
                    "selectedProfile=\(resolvedProfile.rawValue) liveProfile=\(liveProfile.rawValue)"
            )
        }
        return resolvedProfile
    }

    func mirageMediaSendProfile() async -> LoomQueuedUnreliableSendProfile {
        guard let pathSnapshot else {
            return .interactiveMedia
        }
        let mediaProfile = MirageNetworkPathClassifier.classify(pathSnapshot).mediaProfile
        return Self.mirageMediaSendProfile(
            for: mediaProfile,
            transportReceiveSemantics: context?.transportDiagnostics.receiveSemantics
        )
    }

    func mirageAudioSendProfile() async -> LoomQueuedUnreliableSendProfile {
        guard let pathSnapshot else {
            return .interactiveAudio
        }
        let mediaProfile = MirageNetworkPathClassifier.classify(pathSnapshot).mediaProfile
        return mediaProfile.usesAwdlRadioPolicy
            ? .proximityInteractiveAudio
            : .interactiveAudio
    }
}
#endif
