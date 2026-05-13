//
//  MirageHostService+AppWindowSwap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Handles a client request to swap a visible app-stream slot with a hidden window.
    func handleAppWindowSwapRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let request = try message.decode(AppWindowSwapRequestMessage.self)
            let result = await performAppWindowSwap(
                bundleIdentifier: request.bundleIdentifier,
                targetSlotStreamID: request.targetSlotStreamID,
                targetWindowID: request.targetWindowID,
                clientID: clientContext.client.id
            )
            clientContext.queueBestEffort(.appWindowSwapResult, content: result)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle app window swap request: ")
            let fallback = AppWindowSwapResultMessage(
                bundleIdentifier: "",
                targetSlotStreamID: 0,
                mediaStreamID: 0,
                windowID: 0,
                success: false,
                reason: error.localizedDescription
            )
            clientContext.queueBestEffort(.appWindowSwapResult, content: fallback)
        }
    }

    /// Validates ownership and gathers the state needed to perform a window swap.
    func appWindowSwapContext(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID,
        clientID: UUID,
        failure: (String) -> AppWindowSwapResultMessage
    ) async -> AppWindowSwapContextResult {
        guard let appSession = await appStreamManager.session(bundleIdentifier: bundleIdentifier) else {
            return .failure(failure("App session not found"))
        }
        guard appSession.clientID == clientID else {
            return .failure(failure("Swap request client does not own this app session"))
        }
        guard let currentWindowID = await appStreamManager.windowIDForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: targetSlotStreamID
        ) else {
            return .failure(failure("Target slot stream is not active"))
        }
        guard let hiddenInfo = await appStreamManager.hiddenWindowInfo(
            bundleIdentifier: bundleIdentifier,
            windowID: targetWindowID
        ) else {
            return .failure(failure("Target window is not in hidden inventory"))
        }
        guard let streamSession = activeSessionByStreamID[targetSlotStreamID] else {
            return .failure(failure("Target slot stream is unavailable"))
        }
        guard let previousWindowInfo = appSession.windowStreams[currentWindowID] else {
            return .failure(failure("Target slot stream metadata is unavailable"))
        }
        guard let clientContext = findClientContext(clientID: clientID) else {
            return .failure(failure("Client context unavailable"))
        }

        return .success(
            AppWindowSwapContext(
                currentWindowID: currentWindowID,
                hiddenInfo: hiddenInfo,
                streamSession: streamSession,
                previousWindowInfo: previousWindowInfo,
                clientContext: clientContext
            )
        )
    }

    /// Swaps an app-stream slot to a hidden window and reports the client-visible result.
    func performAppWindowSwap(
        bundleIdentifier: String,
        targetSlotStreamID: StreamID,
        targetWindowID: WindowID,
        clientID: UUID
    ) async -> AppWindowSwapResultMessage {
        let failure: (String) -> AppWindowSwapResultMessage = { reason in
            AppWindowSwapResultMessage(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                mediaStreamID: targetSlotStreamID,
                windowID: targetWindowID,
                success: false,
                reason: reason
            )
        }

        let swapContextResult = await appWindowSwapContext(
            bundleIdentifier: bundleIdentifier,
            targetSlotStreamID: targetSlotStreamID,
            targetWindowID: targetWindowID,
            clientID: clientID,
            failure: failure
        )
        let swapContext: AppWindowSwapContext
        switch swapContextResult {
        case let .success(context):
            swapContext = context
        case let .failure(response):
            return response
        }
        let currentWindowID = swapContext.currentWindowID
        let hiddenInfo = swapContext.hiddenInfo
        let streamSession = swapContext.streamSession
        let previousWindowInfo = swapContext.previousWindowInfo
        let clientContext = swapContext.clientContext

        if currentWindowID == targetWindowID {
            return AppWindowSwapResultMessage(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                mediaStreamID: previousWindowInfo.mediaStreamID,
                windowID: targetWindowID,
                success: true,
                reason: nil
            )
        }

        guard let context = streamsByID[targetSlotStreamID] else {
            return await performAppAtlasWindowSwap(
                bundleIdentifier: bundleIdentifier,
                targetSlotStreamID: targetSlotStreamID,
                targetWindowID: targetWindowID,
                currentWindowID: currentWindowID,
                hiddenInfo: hiddenInfo,
                streamSession: streamSession,
                previousWindowInfo: previousWindowInfo,
                clientContext: clientContext,
                clientID: clientID,
                failure: failure
            )
        }

        if let failureReason = await performSharedDisplayAppWindowSwap(
            SharedDisplayAppWindowSwapRequest(
                targetSlotStreamID: targetSlotStreamID,
                targetWindowID: targetWindowID,
                currentWindowID: currentWindowID,
                hiddenInfo: hiddenInfo,
                streamSession: streamSession,
                context: context
            )
        ) {
            return failure(failureReason)
        }

        let targetFrame = currentWindowFrame(for: targetWindowID) ?? CGRect(
            x: streamSession.window.frame.origin.x,
            y: streamSession.window.frame.origin.y,
            width: CGFloat(max(1, hiddenInfo.width)),
            height: CGFloat(max(1, hiddenInfo.height))
        )
        let targetWindow = MirageWindow(
            id: targetWindowID,
            title: hiddenInfo.title,
            application: activeSessionByStreamID[targetSlotStreamID]?.window.application,
            frame: targetFrame,
            isOnScreen: true,
            windowLayer: 0
        )

        registerActiveStreamSession(
            MirageStreamSession(
                id: targetSlotStreamID,
                window: targetWindow,
                client: streamSession.client
            )
        )
        inputStreamCache.set(targetSlotStreamID, window: targetWindow, client: streamSession.client)
        activateWindow(targetWindow)

        let processID = targetWindow.application?.id ?? 0
        let isResizable = appStreamManager.checkWindowResizability(processID: processID)
        await appStreamManager.replaceVisibleWindowForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: targetSlotStreamID,
            newWindowID: targetWindowID,
            title: targetWindow.title,
            width: Int(targetWindow.frame.width),
            height: Int(targetWindow.frame.height),
            isResizable: isResizable,
            capturedClusterWindowIDs: context.capturedWindowClusterWindowIDs,
            mediaStreamID: previousWindowInfo.mediaStreamID
        )
        await appStreamManager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: currentWindowID,
            title: previousWindowInfo.title,
            width: previousWindowInfo.width,
            height: previousWindowInfo.height,
            isResizable: previousWindowInfo.isResizable
        )

        do {
            let streamStart = await context.streamStartSnapshot
            let minSize = await resolvedMinimumSize(for: targetWindow)
            let minWidth = Int(minSize.width)
            let minHeight = Int(minSize.height)
            let started = StreamStartedMessage(
                streamID: targetSlotStreamID,
                windowID: targetWindowID,
                width: streamStart.encodedDimensions.width,
                height: streamStart.encodedDimensions.height,
                frameRate: streamStart.targetFrameRate,
                codec: streamStart.codec,
                minWidth: minWidth,
                minHeight: minHeight,
                dimensionToken: streamStart.dimensionToken,
                acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize
            )
            try await clientContext.send(.streamStarted, content: started)
        } catch {
            return failure("Swap applied but failed to notify client stream metadata: \(error.localizedDescription)")
        }

        await context.requestKeyframeRecoveryIfPossible()
        await markAppStreamInteraction(streamID: targetSlotStreamID, reason: "slot swap")
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleIdentifier, clientID: clientID)
        await recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "slot swap")

        return AppWindowSwapResultMessage(
            bundleIdentifier: bundleIdentifier,
            targetSlotStreamID: targetSlotStreamID,
            mediaStreamID: previousWindowInfo.mediaStreamID,
            windowID: targetWindowID,
            success: true,
            reason: nil
        )
    }

}

#endif
