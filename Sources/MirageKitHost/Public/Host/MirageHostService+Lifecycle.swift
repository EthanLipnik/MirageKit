//
//  MirageHostService+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host lifecycle and window refresh.
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
import Loom

#if os(macOS)

@MainActor
public extension MirageHostService {
    /// Current app-stream sessions, including active and recently reserved sessions.
    var activeStreamingSessions: [MirageAppStreamSession] {
        get async {
            await appStreamManager.allSessions()
        }
    }

    /// Starts host discovery, listeners, window discovery, and runtime monitors.
    func start() async throws {
        guard state == .idle else {
            MirageLogger.host("Already started, state: \(state)")
            return
        }

        await HostDesktopStreamTerminationTracker.shared.reportUncleanTerminationIfNeeded(
            virtualDisplayBackend: platformVirtualDisplayBackend
        )
        state = .starting
        MirageLogger.host("Starting...")

        let maxRetries = 3
        for attempt in 0 ..< maxRetries {
            do {
                try await startListeners()
                break
            } catch where Self.isRetryableListenerStartError(error) {
                MirageLogger.host(
                    "Listener start failed (attempt \(attempt + 1)/\(maxRetries)), cleaning up stale listeners: \(error)"
                )
                await loomNode.stopAdvertising()

                if attempt < maxRetries - 1 {
                    state = .starting
                    try await Task.sleep(for: .seconds(1))
                } else {
                    state = .error(error.localizedDescription)
                    throw error
                }
            }
        }

        // Initial window refresh (non-blocking - may fail if no screen recording permission)
        do {
            try await refreshWindows()
            lastScreenRecordingPermissionDenied = false
            MirageLogger.host("Window refresh complete, found \(availableWindows.count) windows")
        } catch {
            lastScreenRecordingPermissionDenied = Self.isScreenRecordingPermissionDenied(error)
            MirageLogger.host("Initial window refresh failed (screen recording permission may be needed): \(error)")
        }

        ensureScreenParametersObserver()

        await startSessionStateMonitoring()
    }

    private nonisolated static func isRetryableListenerStartError(_ error: Error) -> Bool {
        MirageConnectionErrorClassifier.isRetryableListenerStartError(error)
    }

    private nonisolated static func isScreenRecordingPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }

    /// Applies a live peer-to-peer advertising policy update without tearing down the full host service.
    func updatePeerToPeerAdvertisingEnabled(_ enabled: Bool) async throws {
        let previousConfiguration = loomNode.configuration
        guard previousConfiguration.enablePeerToPeer != enabled else {
            return
        }

        loomNode.configuration.enablePeerToPeer = enabled
        guard case .advertising = state else {
            MirageLogger.host("Updated Proximity Connect advertising policy for next host start: enabled=\(enabled)")
            return
        }

        MirageLogger.host("Restarting Loom advertising for Proximity Connect policy change enabled=\(enabled)")
        stopAdvertisementRefreshLoop()
        await loomNode.stopAdvertising()
        remoteControlPort = nil
        remoteControlListenerReady = false
        await updateRemoteControlListenerState()
        state = .starting

        do {
            try await startListeners()
            await updateRemoteControlListenerState()
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to restart Loom advertising after Proximity Connect policy change: "
            )
            loomNode.configuration = previousConfiguration
            remoteControlPort = nil
            remoteControlListenerReady = false
            await updateRemoteControlListenerState()
            state = .starting
            do {
                try await startListeners()
                await updateRemoteControlListenerState()
                MirageLogger.host("Restored previous Loom advertising policy after failed Proximity Connect update")
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to restore previous Loom advertising policy after Proximity Connect update failure: "
                )
            }
            throw error
        }
    }

    private func startListeners() async throws {
        do {
            MirageLogger.host("Starting Loom authenticated listeners...")
            let ports = try await startAuthenticatedAdvertisingWithDirectPortFallback()
            advertisedPeerAdvertisement = MirageConnectivity.MiragePeerAdvertisementMetadata.updatingDirectTransportPorts(
                ports,
                in: advertisedPeerAdvertisement
            )
            let controlPort = ports[.udp] ?? 0
            remoteControlPort = ports[.udp]
            remoteControlListenerReady = remoteControlPort != nil
            let directTCPPort = ports[.tcp] ?? 0
            MirageLogger.host("Loom authenticated listeners ready udp=\(controlPort) tcp=\(directTCPPort)")
            MirageLogger.host("Host network diagnostics: \(networkDiagnosticsSummaryLines.joined(separator: " | "))")

            state = .advertising(controlPort: controlPort)
            MirageLogger.host("Now advertising on control:\(controlPort)")
            await publishCurrentAdvertisement()
            startAdvertisementRefreshLoop()

            // Set up app streaming callbacks
            setupAppStreamManagerCallbacks()
            await platformVirtualDisplayBackend.setGenerationChangeHandler { [weak self] context, previousGeneration in
                Task { @MainActor [weak self] in
                    await self?.handleSharedDisplayGenerationChange(
                        newContext: context,
                        previousGeneration: previousGeneration
                    )
                }
            }
        } catch {
            if Self.isRetryableListenerStartError(error) {
                MirageLogger.host("Listener start failed: \(error)")
            } else {
                MirageLogger.error(.host, error: error, message: "Failed to start: ")
            }
            state = .error(error.localizedDescription)
            throw error
        }
    }

    private func startAuthenticatedAdvertisingWithDirectPortFallback() async throws -> [LoomTransportKind: UInt16] {
        do {
            return try await startAuthenticatedAdvertisingUsingCurrentConfiguration()
        } catch where Self.isRetryableListenerStartError(error) && hasRequestedDirectListenerPorts {
            let requestedDirectPorts = currentRequestedDirectListenerPorts()
            MirageLogger.host(
                "Configured direct listener ports unavailable; retrying with system-assigned ports: \(error)"
            )
            await loomNode.stopAdvertising()
            clearRequestedDirectListenerPorts()
            defer {
                restoreRequestedDirectListenerPorts(requestedDirectPorts)
            }
            return try await startAuthenticatedAdvertisingUsingCurrentConfiguration()
        }
    }

    private var hasRequestedDirectListenerPorts: Bool {
        loomNode.configuration.controlPort > 0 ||
            loomNode.configuration.udpPort > 0
    }

    private func clearRequestedDirectListenerPorts() {
        loomNode.configuration.controlPort = 0
        loomNode.configuration.udpPort = 0
    }

    private func currentRequestedDirectListenerPorts() -> RequestedDirectListenerPorts {
        RequestedDirectListenerPorts(
            controlPort: loomNode.configuration.controlPort,
            udpPort: loomNode.configuration.udpPort
        )
    }

    private func restoreRequestedDirectListenerPorts(_ ports: RequestedDirectListenerPorts) {
        loomNode.configuration.controlPort = ports.controlPort
        loomNode.configuration.udpPort = ports.udpPort
    }

    private func startAuthenticatedAdvertisingUsingCurrentConfiguration() async throws -> [LoomTransportKind: UInt16] {
        try await loomNode.startAuthenticatedAdvertising(
            serviceName: serviceName,
            helloProvider: { [weak self] in
                guard let self else {
                    throw MirageCore.MirageError.protocolError("Host service deallocated during Loom hello creation")
                }
                return try await MainActor.run {
                    try self.makeSessionHelloRequest()
                }
            }
        ) { [weak self] session in
            Task { @MainActor [weak self] in
                await self?.handleIncomingSession(session)
            }
        }
    }

    /// Stops host discovery, streams, clients, and runtime monitors.
    func stop() async {
        stopAdvertisementRefreshLoop()
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        clearAllPendingAppWindowCloseAlertTokens()
        await platformVirtualDisplayBackend.setGenerationChangeHandler(nil)
        removeScreenParametersObserver()

        stopCursorMonitoring()

        // Clear any stuck modifiers before stopping
        inputController.clearAllModifiers()

        for stream in activeStreams {
            await stopStream(stream)
        }
        for streamID in Array(customStreamSessionsByStreamID.keys) {
            await stopCustomStream(streamID: streamID, reason: .hostShutdown, notifyClient: true)
        }
        windowVirtualDisplayStateByWindowID.removeAll()
        windowVisibleFrameDriftStateByStreamID.removeAll()

        // Disconnect all clients
        for client in connectedClients {
            await disconnectClient(client)
        }

        await restoreStageManagerAfterAppStreamingIfNeeded(force: true)

        hostAudioMuteController.setMuted(false)
        await forceDisableLightsOut(reason: "host service stop")

        // Force release power assertion on full stop
        await PowerAssertionManager.shared.forceDisable()

        await loomNode.stopAdvertising()

        state = .idle
        remoteControlListenerReady = false
        remoteControlPort = nil
    }

    /// Refreshes the host window catalog through the platform backend.
    func refreshWindows() async throws {
        availableWindows = try await platformWindowCatalogBackend.refreshWindows()
    }
}

private struct RequestedDirectListenerPorts {
    let controlPort: UInt16
    let udpPort: UInt16
}
#endif
