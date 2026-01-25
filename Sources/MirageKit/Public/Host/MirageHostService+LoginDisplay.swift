//
//  MirageHostService+LoginDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import Foundation
import Network

#if os(macOS)
import ScreenCaptureKit

// MARK: - Login Display Streaming

extension MirageHostService {
    /// Start login display stream if not already running
    func startLoginDisplayStreamIfNeeded() async {
        guard loginDisplayContext == nil else {
            await broadcastLoginDisplayReady()
            return
        }

        do {
            let displayInfo = try await resolveLoginDisplay()
            let streamID = nextStreamID
            nextStreamID += 1

            let context = StreamContext(
                streamID: streamID,
                windowID: 0,
                encoderConfig: encoderConfig,
                maxPacketSize: networkConfig.maxPacketSize,
                additionalFrameFlags: [.loginDisplay]
            )

            loginDisplayContext = context
            loginDisplayStreamID = streamID
            loginDisplayResolution = displayInfo.resolution

            loginDisplayInputState.update(streamID: streamID, bounds: displayInfo.bounds)

            streamsByID[streamID] = context

            // Enable power assertion to prevent display sleep during login display streaming
            await PowerAssertionManager.shared.enable()

            try await context.startLoginDisplay(
                displayWrapper: displayInfo.displayWrapper,
                resolution: displayInfo.resolution,
                onEncodedFrame: { [weak self] packetData, _, releasePacket in
                    guard let self else {
                        releasePacket()
                        return
                    }
                    Task { @MainActor in
                        self.sendVideoPacketForStream(streamID, data: packetData, onComplete: releasePacket)
                    }
                }
            )

            let encodedDimensions = await context.getEncodedDimensions()
            loginDisplayResolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)

            await broadcastLoginDisplayReady()
        } catch {
            MirageLogger.error(.host, "Failed to start login display stream: \(error)")
        }
    }

    /// Stop the login display stream
    func stopLoginDisplayStream(newState: HostSessionState) async {
        guard let streamID = loginDisplayStreamID else { return }

        if let context = loginDisplayContext {
            await context.stop()
        }

        loginDisplayContext = nil
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        loginDisplayInputState.clear()

        streamsByID.removeValue(forKey: streamID)
        udpConnectionsByStream.removeValue(forKey: streamID)?.cancel()

        // Release login display consumer from SharedVirtualDisplayManager
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.loginDisplay)

        // Disable power assertion if no other streams are active
        if activeStreams.isEmpty {
            await PowerAssertionManager.shared.disable()
        }

        await broadcastLoginDisplayStopped(streamID: streamID, newState: newState)
    }

    /// Broadcast login display ready to all connected clients
    func broadcastLoginDisplayReady() async {
        guard let streamID = loginDisplayStreamID,
              let resolution = loginDisplayResolution else { return }

        // Get dimension token from login display stream context
        let dimensionToken = await loginDisplayContext?.getDimensionToken() ?? 0

        let message = LoginDisplayReadyMessage(
            streamID: UInt32(streamID),
            width: Int(resolution.width),
            height: Int(resolution.height),
            sessionState: sessionState,
            requiresUsername: sessionState.requiresUsername,
            dimensionToken: dimensionToken
        )

        for clientContext in clientsByConnection.values {
            try? await clientContext.send(.loginDisplayReady, content: message)
        }
    }

    /// Broadcast login display stopped to all connected clients
    func broadcastLoginDisplayStopped(streamID: StreamID, newState: HostSessionState) async {
        let message = LoginDisplayStoppedMessage(
            streamID: UInt32(streamID),
            newState: newState
        )

        for clientContext in clientsByConnection.values {
            try? await clientContext.send(.loginDisplayStopped, content: message)
        }
    }

    /// Resolve the login display for streaming
    func resolveLoginDisplay() async throws -> (displayWrapper: SCDisplayWrapper, displayID: CGDirectDisplayID, resolution: CGSize, bounds: CGRect) {
        // Always use SharedVirtualDisplayManager for consistent 2880x1800 resolution
        // This creates the display if needed, or reuses existing one
        let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
            .loginDisplay,
            colorSpace: encoderConfig.colorSpace
        )

        // Wait for display to be available in SCShareableContent
        try await Task.sleep(for: .milliseconds(200))

        let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay()

        guard let bounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() else {
            throw MirageError.protocolError("Shared display exists but couldn't get bounds")
        }

        MirageLogger.host("Login display using shared display \(context.displayID) at \(Int(context.resolution.width))x\(Int(context.resolution.height))")

        return (
            displayWrapper: scDisplay,
            displayID: context.displayID,
            resolution: context.resolution,
            bounds: bounds
        )
    }
}

#endif
