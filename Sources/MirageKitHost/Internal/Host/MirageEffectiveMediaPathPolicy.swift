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
    let clientPolicyPathKind: MirageNetworkPathKind
    let clientPolicyMediaPathProfile: MirageMediaPathProfile
    let transportPathKind: MirageNetworkPathKind
    let mediaPathProfile: MirageMediaPathProfile

    static func resolve(
        hostSnapshot: MirageNetworkPathSnapshot?,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?,
        clientPolicyPathKind: MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMediaPathProfile? = nil
    ) -> MirageEffectiveMediaPathPolicy {
        let hostKind = hostSnapshot?.kind ?? .unknown
        let hostProfile = hostSnapshot?.mediaProfile ?? .unknown
        let clientKind = clientPathKind ?? .unknown
        let clientProfile = clientMediaPathProfile ?? .unknown
        let policyKind = clientPolicyPathKind ?? .unknown
        let policyProfile = clientPolicyMediaPathProfile ?? .unknown
        let resolvedProfile = resolvedMediaPathProfile(
            hostKind: hostKind,
            hostSignature: hostSnapshot?.signature,
            host: hostProfile,
            clientKind: clientKind,
            clientSignature: clientPathSignature,
            client: clientProfile,
            clientPolicyKind: policyKind,
            clientPolicy: policyProfile
        )
        let resolvedKind = resolvedTransportPathKind(
            resolvedProfile: resolvedProfile,
            hostKind: hostKind,
            clientKind: clientKind,
            clientPolicyKind: policyKind
        )

        return MirageEffectiveMediaPathPolicy(
            hostPathKind: hostKind,
            hostMediaPathProfile: hostProfile,
            hostPathSignature: hostSnapshot?.signature,
            clientPathKind: clientKind,
            clientMediaPathProfile: clientProfile,
            clientPathSignature: clientPathSignature,
            clientPolicyPathKind: policyKind,
            clientPolicyMediaPathProfile: policyProfile,
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
        client: MirageMediaPathProfile,
        clientPolicyKind: MirageNetworkPathKind,
        clientPolicy: MirageMediaPathProfile
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
        let policyResolved = resolvedAwdlSideProfile(
            kind: clientPolicyKind,
            profile: clientPolicy,
            signature: clientSignature
        ) ?? clientPolicy

        if policyResolved == .vpnOrOverlay || clientPolicyKind == .vpn {
            return .vpnOrOverlay
        }
        if hostResolved.usesAwdlRadioPolicy || clientResolved.usesAwdlRadioPolicy {
            return .awdlRadio
        }
        if hostResolved == .proximityWiredLike || clientResolved == .proximityWiredLike {
            return .proximityWiredLike
        }
        if policyResolved != .unknown {
            return policyResolved
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
        clientKind: MirageNetworkPathKind,
        clientPolicyKind: MirageNetworkPathKind
    ) -> MirageNetworkPathKind {
        if resolvedProfile == .vpnOrOverlay {
            return .vpn
        }
        if resolvedProfile.usesAwdlRadioPolicy {
            return .awdl
        }
        if clientPolicyKind != .unknown {
            return clientPolicyKind
        }
        if clientKind != .unknown {
            return clientKind
        }
        return hostKind
    }

    var diagnosticSummary: String {
        "hostPath=\(hostPathKind.rawValue)/\(hostMediaPathProfile.rawValue) " +
            "clientPath=\(clientPathKind.rawValue)/\(clientMediaPathProfile.rawValue) " +
            "clientPolicy=\(clientPolicyPathKind.rawValue)/\(clientPolicyMediaPathProfile.rawValue) " +
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
        clientPathSignature: String?,
        clientPolicyPathKind: MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMediaPathProfile? = nil
    ) -> MirageEffectiveMediaPathPolicy {
        let hostSnapshot = currentHostMediaPathSnapshot(
            liveSnapshot: nil,
            bootstrapSnapshot: clientContext.pathSnapshot
        )
        return MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: clientPathKind,
            clientMediaPathProfile: clientMediaPathProfile,
            clientPathSignature: clientPathSignature,
            clientPolicyPathKind: clientPolicyPathKind,
            clientPolicyMediaPathProfile: clientPolicyMediaPathProfile
        )
    }

    func effectiveMediaPathPolicyUsingLiveSession(
        clientContext: ClientContext,
        clientPathKind: MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMediaPathProfile?,
        clientPathSignature: String?,
        clientPolicyPathKind: MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMediaPathProfile? = nil
    ) async -> MirageEffectiveMediaPathPolicy {
        let hostSnapshot = currentHostMediaPathSnapshot(
            liveSnapshot: await clientContext.controlChannel.session.pathSnapshot,
            bootstrapSnapshot: clientContext.pathSnapshot
        )
        return MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: clientPathKind,
            clientMediaPathProfile: clientMediaPathProfile,
            clientPathSignature: clientPathSignature,
            clientPolicyPathKind: clientPolicyPathKind,
            clientPolicyMediaPathProfile: clientPolicyMediaPathProfile
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
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile
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
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile
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
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile
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
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile
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
            clientPathSignature: request.clientPathSignature,
            clientPolicyPathKind: request.clientPolicyPathKind,
            clientPolicyMediaPathProfile: request.clientPolicyMediaPathProfile
        )
    }
}

#endif
