//
//  MirageClientService+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client connection lifecycle and Loom session bootstrap.
//

import Foundation
import Loom
import Network
import MirageKit

#if canImport(UIKit)
import UIKit.UIDevice
#endif

@MainActor
public extension MirageClientService {
    /// Builds the Loom hello request used to authenticate with a discovered host.
    func makeSessionHelloRequest() throws -> LoomSessionHelloRequest {
        let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
        let identity = try resolvedIdentityManager.currentIdentity()
        let deviceType: DeviceType = {
            #if os(macOS)
            return .mac
            #elseif os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
            #elseif os(visionOS)
            return .vision
            #else
            return .unknown
            #endif
        }()
        let advertisement = MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: deviceType,
            identityKeyID: identity.keyID,
            additionalMetadata: additionalAdvertisementMetadata
        )
        return LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: deviceType,
            advertisement: advertisement,
            iCloudUserID: iCloudUserID
        )
    }

    package func makeBootstrapRequest(
        requestTakeoverIfBusy: Bool = false,
        protocolVersionOverride: Int? = nil
    ) -> MirageSessionBootstrapRequest {
        MirageSessionBootstrapRequest(
            protocolVersion: protocolVersionOverride ?? Int(MirageKit.protocolVersion),
            clientRequiresMediaEncryption: networkConfig.requireEncryptedMediaOnLocalNetwork,
            requestTakeoverIfBusy: requestTakeoverIfBusy
        )
    }

    /// Applies runtime network-policy updates used by discovery and hello validation.
    /// Existing connections keep their current transport/path settings until reconnect.
    func updateNetworkPolicy(
        enableBonjour: Bool,
        enablePeerToPeer: Bool,
        preferWiFiBeforeAwdlProximity: Bool,
        requireEncryptedMediaOnLocalNetwork: Bool
    ) {
        guard networkConfig.enableBonjour != enableBonjour ||
            networkConfig.enablePeerToPeer != enablePeerToPeer ||
            self.preferWiFiBeforeAwdlProximity != preferWiFiBeforeAwdlProximity ||
            networkConfig.requireEncryptedMediaOnLocalNetwork != requireEncryptedMediaOnLocalNetwork else {
            return
        }

        networkConfig.enableBonjour = enableBonjour
        networkConfig.enablePeerToPeer = enablePeerToPeer
        self.preferWiFiBeforeAwdlProximity = preferWiFiBeforeAwdlProximity
        networkConfig.requireEncryptedMediaOnLocalNetwork = requireEncryptedMediaOnLocalNetwork
        loomNode.configuration = networkConfig
        MirageLogger.client(
            "Updated network policy (bonjour=\(enableBonjour), p2p=\(enablePeerToPeer), preferWiFiBeforeAwdl=\(preferWiFiBeforeAwdlProximity), localMediaEncryptionRequired=\(requireEncryptedMediaOnLocalNetwork))"
        )
    }

    /// Completes Mirage bootstrap over an already-authenticated Loom session.
    func connect(
        withEstablishedSession session: LoomAuthenticatedSession,
        host: LoomPeer,
        requestTakeoverIfBusy: Bool = false
    ) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        let attemptID = beginConnectAttempt()
        beginConnectionStartupCriticalSection()
        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name) using established session...")
        lastDisconnectReason = nil
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        connectedHostIdentity = nil
        connectedHostAllowsRemoteAccess = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        authorizationState = .verifyingTrust
        hasCompletedBootstrap = false
        connectedHost = host
        clearControlPathState()

        var pendingChannel: MirageControlChannel?

        do {
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            let controlChannel = try await MirageControlChannel.open(on: session)
            pendingChannel = controlChannel
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)
            try await performBootstrap(
                over: controlChannel,
                provisionalHost: host,
                requestTakeoverIfBusy: requestTakeoverIfBusy
            )
            try Task.checkCancellation()
            try throwIfConnectAttemptIsStale(attemptID)

            loomSession = session
            await rememberDirectEndpointHost(session.remoteEndpoint, for: host.deviceID)
            transferEngine = LoomTransferEngine(session: session)
            startTransferObserver()
            self.controlChannel = controlChannel
            await installInputSendHandler(controlChannel: controlChannel)
            installControlSessionObservers(session)
            startMediaStreamListener()
            startReceiving()
            fastPathState.resetInboundActivity(now: CFAbsoluteTimeGetCurrent())
            finishConnectAttempt(attemptID)
            armConnectionStartupIdleRelease()

            // The host immediately streams a large hardware icon (~1 MB) plus
            // app-icon updates after bootstrap.  Give the initial data exchange
            // time to complete before the heartbeat starts probing.
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            startHeartbeat()

            if let acceptedHost = connectedHost {
                MirageLogger.client("Mirage bootstrap accepted for \(acceptedHost.name)")
            }
        } catch {
            clearStartupCriticalSection()
            if let pendingChannel {
                await pendingChannel.cancel()
            }
            let isCurrentAttempt = isCurrentConnectAttempt(attemptID)
            let isCancelledFailure = error is CancellationError || Task.isCancelled || !isCurrentAttempt
            cancelPendingConnectTask(attemptID: attemptID)
            finishConnectAttempt(attemptID)
            if isCancelledFailure {
                MirageLogger.client("Connection attempt cancelled before completion")
            } else if hasCompletedBootstrap {
                MirageLogger.error(.client, error: error, message: "Connection failed: ")
            } else {
                MirageLogger.client("Connection failed before bootstrap completed: \(error.localizedDescription)")
            }
            if !isCancelledFailure {
                MirageInstrumentation.record(.clientConnectionFailed)
            }
            if isCurrentAttempt, requiresDisconnectCleanupAfterFailedConnect {
                await handleDisconnect(
                    reason: error.localizedDescription,
                    state: .disconnected,
                    notifyDelegate: false
                )
            }
            throw error
        }
    }

    /// Connects to a discovered host and performs Mirage bootstrap.
    func connect(
        to host: LoomPeer,
        requestTakeoverIfBusy: Bool = false
    ) async throws {
        try await connect(
            to: host,
            requestTakeoverIfBusy: requestTakeoverIfBusy,
            bootstrapProtocolVersionOverride: nil
        )
    }

    package func connect(
        to host: LoomPeer,
        requestTakeoverIfBusy: Bool = false,
        bootstrapProtocolVersionOverride: Int?
    ) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        let attemptID = beginConnectAttempt()
        beginConnectionStartupCriticalSection()
        MirageInstrumentation.record(.clientConnectionRequested)
        MirageLogger.client("Connecting to \(host.name)...")
        lastDisconnectReason = nil
        connectionState = .connecting
        expectedHostIdentityKeyID = host.advertisement.identityKeyID
        connectedHostIdentityKeyID = nil
        connectedHostIdentity = nil
        connectedHostAllowsRemoteAccess = nil
        mediaPayloadEncryptionEnabled = true
        setMediaSecurityContext(nil)
        authorizationState = .verifyingTrust
        hasCompletedBootstrap = false
        connectedHost = host
        clearControlPathState()

        var pendingChannel: MirageControlChannel?
        let helloRequest = try makeSessionHelloRequest()

        do {
            let bootstrappedSession = try await connectBootstrappedControlSession(
                to: host,
                hello: helloRequest,
                attemptID: attemptID,
                requestTakeoverIfBusy: requestTakeoverIfBusy,
                bootstrapProtocolVersionOverride: bootstrapProtocolVersionOverride
            )
            let session = bootstrappedSession.session
            let controlChannel = bootstrappedSession.controlChannel
            pendingChannel = controlChannel
            loomSession = session
            await rememberDirectEndpointHost(session.remoteEndpoint, for: host.deviceID)
            transferEngine = LoomTransferEngine(session: session)
            startTransferObserver()
            self.controlChannel = controlChannel
            await installInputSendHandler(controlChannel: controlChannel)
            installControlSessionObservers(session)
            startMediaStreamListener()
            startReceiving()
            fastPathState.resetInboundActivity(now: CFAbsoluteTimeGetCurrent())
            finishConnectAttempt(attemptID)
            armConnectionStartupIdleRelease()

            // The host immediately streams a large hardware icon (~1 MB) plus
            // app-icon updates after bootstrap.  Give the initial data exchange
            // time to complete before the heartbeat starts probing.
            heartbeatGraceDeadline = ContinuousClock.now + .seconds(20)
            startHeartbeat()

            if let acceptedHost = connectedHost {
                MirageLogger.client("Mirage bootstrap accepted for \(acceptedHost.name)")
            }
        } catch {
            clearStartupCriticalSection()
            if let pendingChannel {
                await pendingChannel.cancel()
            }
            let isCurrentAttempt = isCurrentConnectAttempt(attemptID)
            let isCancelledFailure = error is CancellationError || Task.isCancelled || !isCurrentAttempt
            cancelPendingConnectTask(attemptID: attemptID)
            finishConnectAttempt(attemptID)
            if isCancelledFailure {
                MirageLogger.client("Connection attempt cancelled before completion")
            } else if hasCompletedBootstrap {
                MirageLogger.error(.client, error: error, message: "Connection failed: ")
            } else {
                MirageLogger.client("Connection failed before bootstrap completed: \(error.localizedDescription)")
            }
            if !isCancelledFailure {
                MirageInstrumentation.record(.clientConnectionFailed)
            }
            if isCurrentAttempt, requiresDisconnectCleanupAfterFailedConnect {
                await handleDisconnect(
                    reason: error.localizedDescription,
                    state: .disconnected,
                    notifyDelegate: false
                )
            }
            throw error
        }
    }

    /// Pause all streams without disconnecting.  The host stops encoding
    /// but keeps virtual displays and stream infrastructure alive so that
    /// `resumeStreaming()` can restart frames immediately with a keyframe.
    func pauseStreaming(backgroundLeaseDuration: TimeInterval? = nil) {
        if let backgroundLeaseDuration {
            let lease = ClientBackgroundLeaseMessage(durationSeconds: backgroundLeaseDuration)
            queueControlMessageBestEffort(.streamPauseAll, content: lease)
            MirageLogger.client(
                "Sent streamPauseAll to host with background lease \(backgroundLeaseDuration)s"
            )
            return
        }

        queueControlMessageBestEffort(ControlMessage(type: .streamPauseAll))
        MirageLogger.client("Sent streamPauseAll to host")
    }

    /// Resume all streams after a pause.  The host forces a keyframe so
    /// the decoder can immediately begin presenting frames again.
    func resumeStreaming() {
        queueControlMessageBestEffort(ControlMessage(type: .streamResumeAll))
        MirageLogger.client("Sent streamResumeAll to host")
    }

    /// Disconnects from the active host and tears down local stream state.
    func disconnect() async {
        cancelPendingConnectTask()
        invalidateCurrentConnectAttempt()

        if let controlChannel, case .connected = connectionState {
            await sendDisconnectNoticeBeforeTeardown(over: controlChannel)
        }

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false,
            forceCleanup: true
        )
    }

    /// Immediately tears down the active host connection without sending a disconnect notice.
    func cancelConnectionImmediately() async {
        cancelPendingConnectTask()
        invalidateCurrentConnectAttempt()

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false,
            forceCleanup: true
        )
    }
}
