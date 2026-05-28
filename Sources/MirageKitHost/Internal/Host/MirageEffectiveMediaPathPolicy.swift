//
//  MirageEffectiveMediaPathPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/27/26.
//

import Foundation
import MirageKit

#if os(macOS)

struct MirageEffectiveMediaPathPolicy: Sendable, Equatable {
    let hostPathKind: MirageNetworkPathKind
    let hostMediaPathProfile: MirageMediaPathProfile
    let hostPathSignature: String?
    let clientPathKind: MirageNetworkPathKind
    let clientMediaPathProfile: MirageMediaPathProfile
    let clientPathSignature: String?
    let transportPathKind: MirageNetworkPathKind
    let mediaPathProfile: MirageMediaPathProfile

    static func resolve(
        hostSnapshot: MirageNetworkPathSnapshot?,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?
    ) -> MirageEffectiveMediaPathPolicy {
        let hostKind = hostSnapshot?.kind ?? .unknown
        let hostProfile = hostSnapshot?.mediaProfile ?? .unknown
        let clientKind = clientPathKind ?? .unknown
        let clientProfile = clientMediaPathProfile ?? .unknown
        let resolvedProfile = resolvedMediaPathProfile(host: hostProfile, client: clientProfile)
        let resolvedKind = resolvedTransportPathKind(
            resolvedProfile: resolvedProfile,
            hostKind: hostKind,
            clientKind: clientKind
        )

        return MirageEffectiveMediaPathPolicy(
            hostPathKind: hostKind,
            hostMediaPathProfile: hostProfile,
            hostPathSignature: hostSnapshot?.signature,
            clientPathKind: clientKind,
            clientMediaPathProfile: clientProfile,
            clientPathSignature: clientPathSignature,
            transportPathKind: resolvedKind,
            mediaPathProfile: resolvedProfile
        )
    }

    private static func resolvedMediaPathProfile(
        host: MirageMediaPathProfile,
        client: MirageMediaPathProfile
    ) -> MirageMediaPathProfile {
        if host.usesAwdlRadioPolicy || client.usesAwdlRadioPolicy {
            return .awdlRadio
        }
        if client != .unknown {
            return client
        }
        return host
    }

    private static func resolvedTransportPathKind(
        resolvedProfile: MirageMediaPathProfile,
        hostKind: MirageNetworkPathKind,
        clientKind: MirageNetworkPathKind
    ) -> MirageNetworkPathKind {
        if resolvedProfile.usesAwdlRadioPolicy {
            return .awdl
        }
        if clientKind != .unknown {
            return clientKind
        }
        return hostKind
    }

    var diagnosticSummary: String {
        "hostPath=\(hostPathKind.rawValue)/\(hostMediaPathProfile.rawValue) " +
            "clientPath=\(clientPathKind.rawValue)/\(clientMediaPathProfile.rawValue) " +
            "resolved=\(transportPathKind.rawValue)/\(mediaPathProfile.rawValue)"
    }
}

extension MirageHostService {
    func effectiveMediaPathPolicy(
        clientContext: ClientContext,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?
    ) -> MirageEffectiveMediaPathPolicy {
        let hostSnapshot = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0) }
        return MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: clientPathKind,
            clientMediaPathProfile: clientMediaPathProfile,
            clientPathSignature: clientPathSignature
        )
    }

    func effectiveMediaPathPolicy(
        for request: StartDesktopStreamMessage,
        clientContext: ClientContext
    ) -> MirageEffectiveMediaPathPolicy {
        effectiveMediaPathPolicy(
            clientContext: clientContext,
            clientPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature
        )
    }

    func effectiveMediaPathPolicy(
        for request: StartStreamMessage,
        clientContext: ClientContext
    ) -> MirageEffectiveMediaPathPolicy {
        effectiveMediaPathPolicy(
            clientContext: clientContext,
            clientPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature
        )
    }

    func effectiveMediaPathPolicy(
        for request: SelectAppMessage,
        clientContext: ClientContext
    ) -> MirageEffectiveMediaPathPolicy {
        effectiveMediaPathPolicy(
            clientContext: clientContext,
            clientPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature
        )
    }

    func effectiveMediaPathPolicy(
        for request: StartCustomStreamMessage,
        clientContext: ClientContext
    ) -> MirageEffectiveMediaPathPolicy {
        effectiveMediaPathPolicy(
            clientContext: clientContext,
            clientPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature
        )
    }
}

#endif
