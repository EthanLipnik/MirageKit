//
//  MirageEffectiveMediaPathPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/27/26.
//

import Foundation
import Loom
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
        let resolvedProfile = resolvedMediaPathProfile(
            hostKind: hostKind,
            hostSignature: hostSnapshot?.signature,
            host: hostProfile,
            clientKind: clientKind,
            clientSignature: clientPathSignature,
            client: clientProfile
        )
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
        hostKind: MirageNetworkPathKind,
        hostSignature: String?,
        host: MirageMediaPathProfile,
        clientKind: MirageNetworkPathKind,
        clientSignature: String?,
        client: MirageMediaPathProfile
    ) -> MirageMediaPathProfile {
        let hostResolved = resolvedAwdlSideProfile(
            kind: hostKind,
            profile: host,
            signature: hostSignature
        ) ?? host
        let clientResolved = resolvedAwdlSideProfile(
            kind: clientKind,
            profile: client,
            signature: clientSignature
        ) ?? client

        if hostResolved.usesAwdlRadioPolicy || clientResolved.usesAwdlRadioPolicy {
            return .awdlRadio
        }
        if hostResolved == .proximityWiredLike || clientResolved == .proximityWiredLike {
            return .proximityWiredLike
        }
        if clientResolved != .unknown {
            return clientResolved
        }
        return hostResolved
    }

    private static func resolvedAwdlSideProfile(
        kind: MirageNetworkPathKind,
        profile: MirageMediaPathProfile,
        signature: String?
    ) -> MirageMediaPathProfile? {
        guard kind == .awdl else { return nil }
        if profile.usesAwdlRadioPolicy {
            return .awdlRadio
        }
        switch profile {
        case .proximityWiredLike:
            return pathSignatureHasApplePrivateNCM(signature) ? .proximityWiredLike : .awdlRadio
        case .wired:
            return pathSignatureHasBridge(signature) ? .wired : .awdlRadio
        case .vpnOrOverlay:
            return .vpnOrOverlay
        case .awdlRadio,
             .localWiFi,
             .other,
             .unknown:
            return .awdlRadio
        }
    }

    private static func pathSignatureHasApplePrivateNCM(_ signature: String?) -> Bool {
        interfaceNames(from: signature).contains {
            $0.hasPrefix("anpi") || $0.hasPrefix("apni")
        }
    }

    private static func pathSignatureHasBridge(_ signature: String?) -> Bool {
        interfaceNames(from: signature).contains {
            $0.hasPrefix("bridge") || $0.contains("thunderbolt")
        }
    }

    private static func interfaceNames(from signature: String?) -> [String] {
        guard let signature else { return [] }
        let fields = signature.split(separator: "|", omittingEmptySubsequences: false)
        guard let interfaceField = fields.first(where: { $0.hasPrefix("if=") }) else {
            return []
        }
        return interfaceField
            .dropFirst(3)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
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

func currentHostMediaPathSnapshot(
    liveSnapshot: LoomSessionNetworkPathSnapshot?,
    bootstrapSnapshot: LoomSessionNetworkPathSnapshot?
) -> MirageNetworkPathSnapshot? {
    (liveSnapshot ?? bootstrapSnapshot).map { MirageNetworkPathClassifier.classify($0) }
}

extension MirageHostService {
    func effectiveMediaPathPolicy(
        clientContext: ClientContext,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?
    ) -> MirageEffectiveMediaPathPolicy {
        let hostSnapshot = currentHostMediaPathSnapshot(
            liveSnapshot: nil,
            bootstrapSnapshot: clientContext.pathSnapshot
        )
        return MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: clientPathKind,
            clientMediaPathProfile: clientMediaPathProfile,
            clientPathSignature: clientPathSignature
        )
    }

    func effectiveMediaPathPolicyUsingLiveSession(
        clientContext: ClientContext,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?
    ) async -> MirageEffectiveMediaPathPolicy {
        let hostSnapshot = currentHostMediaPathSnapshot(
            liveSnapshot: await clientContext.controlChannel.session.pathSnapshot,
            bootstrapSnapshot: clientContext.pathSnapshot
        )
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

    func effectiveMediaPathPolicyUsingLiveSession(
        for request: StartDesktopStreamMessage,
        clientContext: ClientContext
    ) async -> MirageEffectiveMediaPathPolicy {
        await effectiveMediaPathPolicyUsingLiveSession(
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
