//
//  MirageClientService+MessageHandling+Core.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Core control message handling.
//

import Foundation
import MirageKit
import Network

@MainActor
extension MirageClientService {
    /// Commits an accepted bootstrap response into connected-host identity and connection state.
    func finalizeAcceptedBootstrap(
        _ response: MirageSessionBootstrapResponse,
        hostIdentityKeyID: String
    ) async -> LoomPeer {
        connectedHostIdentityKeyID = hostIdentityKeyID
        hasCompletedBootstrap = true
        authorizationState = .approved

        let acceptedHost = await canonicalConnectedHost(
            hostID: response.hostID,
            hostName: response.hostName,
            hostIdentityKeyID: hostIdentityKeyID
        )
        let provisionalHost = connectedHost
        connectedHostIdentity = MirageConnectedHostIdentity(
            acceptedHostID: response.hostID,
            identityKeyID: hostIdentityKeyID,
            provisionalHostID: provisionalHost?.deviceID,
            advertisedHostID: provisionalHost?.advertisement.deviceID
        )
        connectedHost = acceptedHost
        connectionState = .connected(host: acceptedHost.name)
        return acceptedHost
    }

    /// Builds the canonical connected host from accepted identity and provisional transport metadata.
    func canonicalConnectedHost(
        hostID: UUID,
        hostName: String,
        hostIdentityKeyID: String
    ) async -> LoomPeer {
        let provisionalHost = connectedHost
        let resolvedHostName =
            hostName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? provisionalHost?.name ?? "Host" : hostName
        let controlRemoteEndpoint = if let loomSession {
            await loomSession.remoteEndpoint
        } else {
            connectedHost?.endpoint
        }
        let hostEndpoint: NWEndpoint =
            provisionalHost?.endpoint
                ?? controlRemoteEndpoint
                ?? .service(
                    name: resolvedHostName,
                    type: MirageKit.serviceType,
                    domain: "",
                    interface: nil
                )
        let deviceType =
            provisionalHost?.deviceType
                ?? provisionalHost?.advertisement.deviceType
                ?? .unknown
        let sourceAdvertisement = provisionalHost?.advertisement ?? LoomPeerAdvertisement()
        let canonicalAdvertisement = LoomPeerAdvertisement(
            protocolVersion: sourceAdvertisement.protocolVersion,
            deviceID: hostID,
            identityKeyID: hostIdentityKeyID,
            deviceType: sourceAdvertisement.deviceType ?? deviceType,
            modelIdentifier: sourceAdvertisement.modelIdentifier,
            iconName: sourceAdvertisement.iconName,
            machineFamily: sourceAdvertisement.machineFamily,
            hostName: sourceAdvertisement.hostName,
            directTransports: sourceAdvertisement.directTransports,
            metadata: sourceAdvertisement.metadata
        )

        if let provisionalHost, provisionalHost.deviceID != hostID {
            MirageLogger.client(
                "Canonicalizing connected host identity provisional=\(provisionalHost.deviceID.uuidString) accepted=\(hostID.uuidString)"
            )
        }

        return LoomPeer(
            id: hostID,
            name: resolvedHostName,
            deviceType: deviceType,
            endpoint: hostEndpoint,
            advertisement: canonicalAdvertisement,
            resolvedAddresses: provisionalHost?.resolvedAddresses ?? [],
            discoveredInterfaces: provisionalHost?.discoveredInterfaces ?? []
        )
    }

    /// Returns whether the accepted session satisfies the client's media-encryption policy.
    nonisolated static func shouldAcceptSessionMediaEncryption(
        mediaEncryptionEnabled: Bool,
        requireEncryptedMediaOnLocalNetwork: Bool
    ) -> Bool {
        mediaEncryptionEnabled || !requireEncryptedMediaOnLocalNetwork
    }

    /// Extracts protocol mismatch metadata from a rejected bootstrap response.
    func protocolMismatchInfo(from response: MirageSessionBootstrapResponse)
    -> ProtocolMismatchInfo? {
        guard response.rejectionReason == .protocolVersionMismatch else {
            return nil
        }
        return ProtocolMismatchInfo(
            reason: ProtocolMismatchInfo.Reason(
                bootstrapRejectionReason: response.rejectionReason
            ),
            hostProtocolVersion: response.protocolMismatchHostVersion,
            clientProtocolVersion: response.protocolMismatchClientVersion
        )
    }

    /// Converts a rejected bootstrap response into the client-facing connection rejection model.
    func connectionRejection(from response: MirageSessionBootstrapResponse)
    -> MirageConnectionRejection {
        MirageConnectionRejection(
            reason: MirageConnectionRejection.Reason(bootstrapRejectionReason: response.rejectionReason),
            hostName: response.hostName,
            hostProtocolVersion: response.protocolMismatchHostVersion,
            clientProtocolVersion: response.protocolMismatchClientVersion,
            recoveryHint: bootstrapRejectionDescription(
                for: response,
                mismatchInfo: protocolMismatchInfo(from: response)
            )
        )
    }

    /// Produces the user-facing bootstrap rejection recovery hint.
    func bootstrapRejectionDescription(
        for response: MirageSessionBootstrapResponse,
        mismatchInfo: ProtocolMismatchInfo?
    ) -> String {
        if let mismatchInfo {
            let hostVersion = mismatchInfo.hostProtocolVersion.map(String.init) ?? "unknown"
            let clientVersion = mismatchInfo.clientProtocolVersion.map(String.init) ?? "unknown"
            return "Protocol mismatch (host \(hostVersion), client \(clientVersion))."
        }

        switch response.rejectionReason {
        case .hostBusy:
            return "Host is already connected to another client."
        case .hostUpdateInProgress:
            return "Host update is in progress."
        case .unauthorized:
            return "Connection rejected by host authorization policy."
        case .takeoverRequiresTrustedRequester:
            return "Host is busy and takeover requires a trusted client."
        case .rejected:
            return "Connection rejected by host."
        case .protocolVersionMismatch:
            return "Protocol mismatch."
        case .none:
            return "Connection rejected."
        }
    }

    /// Applies an accepted bootstrap response or throws the mapped rejection error.
    func handleBootstrapResponse(
        _ response: MirageSessionBootstrapResponse,
        provisionalHost: LoomPeer,
        session: LoomAuthenticatedSession
    ) async throws {
        guard let context = await session.context else {
            throw MirageError.protocolError("Loom session missing authenticated context")
        }

        let peerIdentity = context.peerIdentity
        guard let hostIdentityKeyID = peerIdentity.identityKeyID else {
            throw MirageError.protocolError(
                "Authenticated Loom session is missing host identity key"
            )
        }
        if let expectedHostIdentityKeyID, expectedHostIdentityKeyID != hostIdentityKeyID {
            throw MirageError.protocolError("Host identity mismatch")
        }

        if response.accepted {
            guard
                Self.shouldAcceptSessionMediaEncryption(
                    mediaEncryptionEnabled: response.mediaEncryptionEnabled,
                    requireEncryptedMediaOnLocalNetwork: networkConfig
                        .requireEncryptedMediaOnLocalNetwork
                ) else {
                throw MirageError.protocolError(
                    "Host media encryption disabled (client policy blocks unencrypted media)"
                )
            }
            guard response.datagramRegistrationToken.count == MirageMediaSecurity.registrationTokenLength else {
                throw MirageError.protocolError("Invalid datagram registration token")
            }

            let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
            let localIdentity = try resolvedIdentityManager.currentIdentity()
            let mediaContext = try MirageMediaSecurity.deriveContextForAuthenticatedSession(
                identityManager: resolvedIdentityManager,
                peerPublicKey: peerIdentity.identityPublicKey ?? Data(),
                hostID: response.hostID,
                clientID: deviceID,
                hostKeyID: hostIdentityKeyID,
                clientKeyID: localIdentity.keyID,
                datagramRegistrationToken: response.datagramRegistrationToken
            )

            setMediaSecurityContext(mediaContext)
            mediaPayloadEncryptionEnabled = response.mediaEncryptionEnabled
            connectedHostAllowsRemoteAccess = response.remoteAccessAllowed
            let acceptedHost = await finalizeAcceptedBootstrap(
                response,
                hostIdentityKeyID: hostIdentityKeyID
            )

            if response.autoTrustGranted {
                let hostComponent = response.hostID.uuidString.lowercased()
                let noticeKey = "com.mirage.autotrust.client.\(hostComponent)"
                if !UserDefaults.standard.bool(forKey: noticeKey) {
                    UserDefaults.standard.set(true, forKey: noticeKey)
                    let hostDisplayName = response.hostName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if hostDisplayName.isEmpty {
                        onAutoTrustNotice?("Auto-approved trusted device for this host.")
                    } else {
                        onAutoTrustNotice?("Auto-approved trusted device for \(hostDisplayName).")
                    }
                }
            }

            MirageLogger.client("Mirage bootstrap accepted by \(acceptedHost.name)")
            MirageInstrumentation.record(.clientHelloAccepted)
            if connectedHost == nil {
                connectedHost = provisionalHost
            }
        } else {
            let mismatchInfo = protocolMismatchInfo(from: response)
            if let mismatchInfo {
                onProtocolMismatch?(mismatchInfo)
            }
            let rejection = connectionRejection(from: response)
            MirageLogger.client("Connection rejected by host: \(rejection.userFacingMessage)")
            MirageInstrumentation.record(
                .clientHelloRejected(
                    MirageHelloRejectionStepReason(bootstrapRejectionReason: response.rejectionReason)
                )
            )
            throw MirageError.connectionRejected(rejection)
        }
    }

    /// Stores a full host window snapshot unless control updates are currently suppressed.
    func handleWindowList(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsWindowListRefresh = true
            return
        }
        do {
            let windowList = try message.decode(WindowListMessage.self)
            MirageLogger.client("Received window list with \(windowList.windows.count) windows")
            for window in windowList.windows {
                MirageLogger.client(
                    "  - \(window.application?.name ?? "Unknown"): \(window.title ?? "Untitled")"
                )
            }
            hasReceivedWindowList = true
            availableWindows = windowList.windows
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window list: ")
        }
    }

    /// Applies incremental host window additions, removals, and metadata updates.
    func handleWindowUpdate(_ message: ControlMessage) {
        guard controlUpdatePolicy != .interactiveStreaming else {
            deferredControlRefreshRequirements.needsWindowListRefresh = true
            return
        }
        let update: WindowUpdateMessage
        do {
            update = try message.decode(WindowUpdateMessage.self)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window update: ")
            return
        }
        for window in update.added where !availableWindows.contains(where: { $0.id == window.id }) {
            availableWindows.append(window)
        }
        for id in update.removed {
            availableWindows.removeAll { $0.id == id }
        }
        for window in update.updated {
            if let index = availableWindows.firstIndex(where: { $0.id == window.id }) {
                availableWindows[index] = window
            }
        }
    }

    /// Maps a host error message into pending-startup cleanup or delegate error delivery.
    func handleErrorMessage(_ message: ControlMessage) {
        let errorMessage: ErrorMessage
        do {
            errorMessage = try message.decode(ErrorMessage.self)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode error message: ")
            return
        }
        if desktopStreamMode != nil || desktopStreamRequestStartTime > 0, desktopStreamID == nil {
            clearPendingDesktopStreamStartState()
        }
        if errorMessage.code == .appStreamStartupFailed {
            pendingAppRequestedColorDepth = nil
            pendingAppRequestedLatencyMode = nil
            clearPendingStreamSetup(kind: .app)
            onAppStreamStartupFailed?(
                AppStreamStartupFailure(
                    bundleIdentifier: errorMessage.bundleIdentifier,
                    message: errorMessage.message
                )
            )
            return
        }
        if let runtimeCondition = errorMessage.code.runtimeConditionError {
            delegate?.didEncounterError(runtimeCondition)
        } else {
            delegate?.didEncounterError(MirageError.protocolError(errorMessage.message))
        }
    }

    /// Applies a host disconnect notice through the normal client disconnect path.
    func handleDisconnectMessage(_ message: ControlMessage) async {
        let disconnect: DisconnectMessage
        do {
            disconnect = try message.decode(DisconnectMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode disconnect message: "
            )
            return
        }
        await handleDisconnect(
            reason: disconnect.reason.rawValue,
            state: .disconnected,
            notifyDelegate: true
        )
    }

    /// Updates host login-session state and notifies the client delegate.
    func handleSessionStateUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(SessionStateUpdateMessage.self)
            MirageLogger.client(
                "Host session state: \(update.state), requires username: \(update.requiresUserIdentifier)"
            )
            hostSessionState = update.state
            currentSessionToken = update.sessionToken
            delegate?.hostSessionStateChanged(update.state)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode session state update: "
            )
        }
    }
}
