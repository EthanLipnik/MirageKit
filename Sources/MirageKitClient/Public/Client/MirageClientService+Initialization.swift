//
//  MirageClientService+Initialization.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Loom
import MirageKit

/// Initialization helpers for client transport, audio, and session-store wiring.
@MainActor
extension MirageClientService {
    /// Returns a Mirage-specific Loom configuration for client discovery and session setup.
    static func resolvedNetworkConfiguration(
        from loomConfiguration: LoomNetworkConfiguration
    ) -> LoomNetworkConfiguration {
        var resolvedConfiguration = loomConfiguration
        if resolvedConfiguration.serviceType == Loom.serviceType {
            resolvedConfiguration.serviceType = MirageKit.serviceType
        }
        resolvedConfiguration.enabledDirectTransports = MirageKit.mirageAppDirectTransports
        resolvedConfiguration.quicPort = 0
        resolvedConfiguration.quicALPN = []
        return resolvedConfiguration
    }

    /// Connects decoded-audio delivery from the ingress queue back into the client service.
    func configureAudioPacketIngressQueue() {
        audioPacketIngressQueue.setDeliverHandler { [weak self] decodedFrames, streamID in
            self?.enqueueDecodedAudioFrames(decodedFrames, for: streamID)
        }
    }

    /// Wires session-store callbacks that need to call back into the owning client service.
    func configureSessionStoreCallbacks() {
        sessionStore.clientService = self
        sessionStore.onStreamPresentationTierChanged = { [weak self] streamID, tier in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await applyStreamPresentationTier(tier, to: streamID)
            }
        }
    }
}
