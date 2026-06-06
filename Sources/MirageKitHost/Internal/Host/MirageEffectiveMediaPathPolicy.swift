//
//  MirageEffectiveMediaPathPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/27/26.
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

#if os(macOS)

struct MirageEffectiveMediaPathPolicy: Sendable, Equatable {
    let hostPathKind: MirageCore.MirageNetworkPathKind
    let hostMediaPathProfile: MirageMedia.MirageMediaPathProfile
    let hostPathSignature: String?
    let clientPathKind: MirageCore.MirageNetworkPathKind
    let clientMediaPathProfile: MirageMedia.MirageMediaPathProfile
    let clientPathSignature: String?
    let clientPolicyPathKind: MirageCore.MirageNetworkPathKind
    let clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile
    let transportPathKind: MirageCore.MirageNetworkPathKind
    let mediaPathProfile: MirageMedia.MirageMediaPathProfile

    static func resolve(
        hostSnapshot: MirageConnectivity.MirageNetworkPathSnapshot?,
        clientPathKind: MirageCore.MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMedia.MirageMediaPathProfile?,
        clientPathSignature: String?,
        clientPolicyPathKind: MirageCore.MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
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
        hostKind: MirageCore.MirageNetworkPathKind,
        hostSignature: String?,
        host: MirageMedia.MirageMediaPathProfile,
        clientKind: MirageCore.MirageNetworkPathKind,
        clientSignature: String?,
        client: MirageMedia.MirageMediaPathProfile,
        clientPolicyKind: MirageCore.MirageNetworkPathKind,
        clientPolicy: MirageMedia.MirageMediaPathProfile
    ) -> MirageMedia.MirageMediaPathProfile {
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
        kind: MirageCore.MirageNetworkPathKind,
        profile: MirageMedia.MirageMediaPathProfile,
        signature: String?
    ) -> MirageMedia.MirageMediaPathProfile? {
        guard kind == .awdl else { return nil }
        if profile == .vpnOrOverlay {
            return .vpnOrOverlay
        }
        if pathSignatureHasLowLatencyWireless(signature) && !pathSignatureHasAWDL(signature) {
            return .localWiFi
        }
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
             .other,
             .unknown:
            return .awdlRadio
        case .localWiFi:
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

    private static func pathSignatureHasLowLatencyWireless(_ signature: String?) -> Bool {
        interfaceNames(from: signature).contains { $0.hasPrefix("llw") }
    }

    private static func pathSignatureHasAWDL(_ signature: String?) -> Bool {
        interfaceNames(from: signature).contains { $0.hasPrefix("awdl") }
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
        resolvedProfile: MirageMedia.MirageMediaPathProfile,
        hostKind: MirageCore.MirageNetworkPathKind,
        clientKind: MirageCore.MirageNetworkPathKind,
        clientPolicyKind: MirageCore.MirageNetworkPathKind
    ) -> MirageCore.MirageNetworkPathKind {
        if resolvedProfile == .vpnOrOverlay {
            return .vpn
        }
        if resolvedProfile.usesAwdlRadioPolicy {
            return .awdl
        }
        if resolvedProfile == .proximityWiredLike || resolvedProfile == .wired {
            return .wired
        }
        if resolvedProfile == .localWiFi, clientKind == .awdl {
            return .wifi
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

extension MirageHostService {
    func effectiveMediaPathPolicy(
        clientContext: ClientContext,
        clientPathKind: MirageCore.MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMedia.MirageMediaPathProfile?,
        clientPathSignature: String?,
        clientPolicyPathKind: MirageCore.MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
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
        clientPathKind: MirageCore.MirageNetworkPathKind?,
        clientMediaPathProfile: MirageMedia.MirageMediaPathProfile?,
        clientPathSignature: String?,
        clientPolicyPathKind: MirageCore.MirageNetworkPathKind? = nil,
        clientPolicyMediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
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
        for request: MirageWire.StartDesktopStreamMessage,
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
        for request: MirageWire.StartDesktopStreamMessage,
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
        for request: MirageWire.StartStreamMessage,
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
        for request: MirageWire.SelectAppMessage,
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
        for request: MirageWire.StartCustomStreamMessage,
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
