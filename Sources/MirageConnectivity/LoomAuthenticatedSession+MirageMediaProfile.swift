//
//  LoomAuthenticatedSession+MirageMediaProfile.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageCore
import MirageMedia

#if os(macOS)
package extension LoomAuthenticatedSession {
    private static var independentUnreliableReceiveSemantics: String {
        "independent-reliable-unreliable"
    }

    static func mirageMediaSendProfile(for mediaPathProfile: MirageMedia.MirageMediaPathProfile) -> MirageMedia.MirageMediaSendProfile {
        mirageMediaSendProfile(
            for: mediaPathProfile,
            transportReceiveSemantics: nil
        )
    }

    static func mirageMediaSendProfile(
        for mediaPathProfile: MirageMedia.MirageMediaPathProfile,
        transportReceiveSemantics: String?
    ) -> MirageMedia.MirageMediaSendProfile {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return .interactiveMedia }
        guard let transportReceiveSemantics else { return .proximityRealtimeDisplay }
        guard transportReceiveSemantics == Self.independentUnreliableReceiveSemantics else {
            return .proximityRealtimeDisplaySingleLane
        }
        return .proximityRealtimeDisplay
    }

    func mirageMediaSendProfile(
        resolvedMediaPathProfile: MirageMedia.MirageMediaPathProfile,
        streamID: StreamID,
        phase: String,
        logHostEvent: @Sendable (String) -> Void
    ) async -> MirageMedia.MirageMediaSendProfile {
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
            logHostEvent(
                "event=media_send_profile_downgrade phase=\(phase) stream=\(streamID) " +
                    "resolvedMediaPath=\(resolvedMediaPathProfile.rawValue) " +
                    "preferredProfile=\(preferredProfile.rawValue) " +
                    "selectedProfile=\(resolvedProfile.rawValue) " +
                    "transport=\(transport) receiveSemantics=\(semantics)"
            )
        }
        let liveProfile = await mirageMediaSendProfile()
        if liveProfile != resolvedProfile {
            logHostEvent(
                "event=media_send_profile_mismatch phase=\(phase) stream=\(streamID) " +
                    "resolvedMediaPath=\(resolvedMediaPathProfile.rawValue) " +
                    "selectedProfile=\(resolvedProfile.rawValue) liveProfile=\(liveProfile.rawValue)"
            )
        }
        return resolvedProfile
    }

    func mirageMediaSendProfile() async -> MirageMedia.MirageMediaSendProfile {
        guard let pathSnapshot else {
            return .interactiveMedia
        }
        let mediaProfile = MirageNetworkPathClassifier.classify(pathSnapshot).mediaProfile
        return Self.mirageMediaSendProfile(
            for: mediaProfile,
            transportReceiveSemantics: context?.transportDiagnostics.receiveSemantics
        )
    }

    func mirageAudioSendProfile() async -> MirageMedia.MirageMediaSendProfile {
        guard let pathSnapshot else {
            return .interactiveAudio
        }
        let mediaProfile = MirageNetworkPathClassifier.classify(pathSnapshot).mediaProfile
        return mediaProfile.usesAwdlRadioPolicy
            ? .proximityInteractiveAudio
            : .interactiveAudio
    }

    private static func miragePreferredMediaSendProfile(
        for mediaPathProfile: MirageMedia.MirageMediaPathProfile
    ) -> MirageMedia.MirageMediaSendProfile {
        mediaPathProfile.usesAwdlRadioPolicy
            ? .proximityRealtimeDisplay
            : .interactiveMedia
    }
}
#endif
