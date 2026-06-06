//
//  MirageClientService+MessageHandling+App.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App-centric streaming message handling.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Publishes app-stream startup metadata and resets stale inventory state.
    func handleAppStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AppStreamStartedMessage.self)
            MirageLogger.client("App stream started: \(started.appName) with \(started.windows.count) windows")
            appStreamStartTimeoutTask?.cancel()
            appStreamStartTimeoutTask = nil
            streamingAppBundleID = started.bundleIdentifier
            appWindowInventory = nil
            storeAppAtlasLayouts(started.atlasLayouts)
            onAppStreamStarted?(started)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app stream started: ")
        }
    }

    /// Applies app-atlas media metadata and prepares or refreshes the media stream controller.
    func handleAppAtlasMediaUpdate(_ message: ControlMessage) async {
        do {
            let update = try message.decode(AppAtlasMediaUpdateMessage.self)
            let mediaStreamID = update.mediaStreamID
            guard shouldAcceptStartupAttempt(update.startupAttemptID, for: mediaStreamID) else {
                MirageLogger.client(
                    "Ignoring stale appAtlasMediaUpdate for media stream \(mediaStreamID) startupAttemptID=\(update.startupAttemptID.uuidString)"
                )
                return
            }

            storeAppAtlasLayout(update.layout)
            activeStreamCodecs[mediaStreamID] = update.codec
            appStreamStartAcknowledgementByStreamID[mediaStreamID] = StreamStartAcknowledgement(
                width: update.width,
                height: update.height,
                dimensionToken: update.dimensionToken
            )

            let hasController = controllersByStream[mediaStreamID] != nil
            let isExistingStream = activeStreamIDsForFiltering.contains(mediaStreamID) || hasController
            let previousDimensionToken = appDimensionTokenByStream[mediaStreamID]
            let acceptedMediaMaxPacketSize = resolvedAcceptedMediaMaxPacketSize(update.acceptedPacketSize)
            let previousMediaMaxPacketSize = mediaMaxPacketSizeByStream[mediaStreamID] ?? mirageDefaultMaxPacketSize
            let packetSizeChanged = hasController && previousMediaMaxPacketSize != acceptedMediaMaxPacketSize
            let didAdvanceDimensionToken =
                if let previousDimensionToken, let dimensionToken = update.dimensionToken {
                    previousDimensionToken != dimensionToken
                } else {
                    false
                }
            let shouldResetController =
                !isExistingStream ||
                !hasController ||
                didAdvanceDimensionToken
            let shouldSetupController = shouldResetController || packetSizeChanged || !hasController

            if let dimensionToken = update.dimensionToken {
                appDimensionTokenByStream[mediaStreamID] = dimensionToken
            }
            registerStartupAttempt(update.startupAttemptID, for: mediaStreamID)
            applyRenderLatencyMode(
                to: mediaStreamID,
                preferredLatencyMode: pendingStreamSetupLatencyMode ?? pendingAppRequestedLatencyMode
            )
            await applyStreamCadenceTarget(
                update.frameRate,
                for: mediaStreamID,
                reason: "app atlas media update"
            )

            if shouldSetupController {
                streamStartupBaseTimes[mediaStreamID] = CFAbsoluteTimeGetCurrent()
                streamStartupFirstRegistrationSent.remove(mediaStreamID)
                streamStartupFirstPacketReceived.remove(mediaStreamID)
                fastPathState.markStartupPacketPending(mediaStreamID)
                await setupControllerForStream(
                    mediaStreamID,
                    codec: update.codec,
                    streamDimensions: (width: update.width, height: update.height),
                    mediaMaxPacketSize: acceptedMediaMaxPacketSize,
                    dimensionToken: update.dimensionToken,
                    targetFrameRate: update.frameRate
                )
            } else if let dimensionToken = update.dimensionToken,
                      let controller = controllersByStream[mediaStreamID] {
                let reassembler = controller.reassembler
                reassembler.updateExpectedDimensionToken(dimensionToken)
                await controller.setDecoderCodec(
                    update.codec,
                    streamDimensions: (width: update.width, height: update.height)
                )
            }

            fastPathState.addActiveStreamID(mediaStreamID)
            processBufferedEarlyVideoPacketIfNeeded(streamID: mediaStreamID)
            registeredStreamIDs.insert(mediaStreamID)
            await updateReassemblerSnapshot()
            if shouldSetupController {
                startStartupRegistrationRetry(streamID: mediaStreamID)
            }
            MirageLogger.client(
                "App-atlas media updated stream=\(mediaStreamID) size=\(update.width)x\(update.height) layoutEpoch=\(update.layoutEpoch)"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-atlas media update: ")
        }
    }

    /// Stores the latest app-window inventory and any atlas layouts bundled with it.
    func handleAppWindowInventory(_ message: ControlMessage) {
        do {
            let inventory = try message.decode(AppWindowInventoryMessage.self)
            storeAppAtlasLayouts(inventory.atlasLayouts)
            appWindowInventory = inventory
            onAppWindowInventoryUpdate?(inventory)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app window inventory: ")
        }
    }

    /// Applies a terminal host-side app-window resize result.
    func handleAppWindowResizeResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(AppWindowResizeResultMessage.self)
            appWindowResizeResultByStreamID[result.streamID] = result
            if let observedWidth = result.observedWidth,
               let observedHeight = result.observedHeight,
               observedWidth > 0,
               observedHeight > 0 {
                let acknowledgement = StreamStartAcknowledgement(
                    width: observedWidth,
                    height: observedHeight,
                    dimensionToken: appDimensionTokenByStream[result.mediaStreamID] ??
                        appDimensionTokenByStream[result.streamID]
                )
                appStreamStartAcknowledgementByStreamID[result.streamID] = acknowledgement
            }
            MirageLogger.client(
                "App-window resize result stream=\(result.streamID) media=\(result.mediaStreamID) " +
                    "outcome=\(result.outcome.rawValue) requested=\(result.requestedWidth)x\(result.requestedHeight) " +
                    "observed=\(result.observedWidth.map(String.init) ?? "nil")x\(result.observedHeight.map(String.init) ?? "nil")"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-window resize result: ")
        }
    }

    /// Forwards a host close-blocked alert for app-window UI presentation.
    func handleAppWindowCloseBlockedAlert(_ message: ControlMessage) {
        do {
            let alert = try message.decode(AppWindowCloseBlockedAlertMessage.self)
            onAppWindowCloseBlockedAlert?(alert)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-window close blocked alert: ")
        }
    }

    /// Reports that a hidden app window was promoted into a visible stream.
    func handleWindowAddedToStream(_ message: ControlMessage) {
        do {
            let added = try message.decode(WindowAddedToStreamMessage.self)
            MirageLogger.client("Window added to stream: \(added.windowID)")
            storeAppAtlasLayouts(added.atlasLayouts)
            clearPendingStreamSetup(kind: .app)
            onWindowAddedToStream?(added)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window added: ")
        }
    }

    /// Reports that a window left an app stream and forwards the host removal reason.
    func handleWindowRemovedFromStream(_ message: ControlMessage) async {
        do {
            let removed = try message.decode(WindowRemovedFromStreamMessage.self)
            MirageLogger.client("Window removed from stream: \(removed.windowID), reason=\(removed.reason.rawValue)")
            onWindowRemovedFromStream?(removed)
            if let streamID = removed.streamID {
                await forceStopWindowStreamLocally(streamID: streamID)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window removed: ")
        }
    }

    /// Reports a host-side failure to start or maintain a specific window stream.
    func handleWindowStreamFailed(_ message: ControlMessage) {
        do {
            let failed = try message.decode(WindowStreamFailedMessage.self)
            MirageLogger.client("Window stream failed: \(failed.windowID) reason=\(failed.reason)")
            onWindowStreamFailed?(failed)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode window stream failed: ")
        }
    }

    /// Applies app-window swap results and updates the target session atlas region on success.
    func handleAppWindowSwapResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(AppWindowSwapResultMessage.self)
            storeAppAtlasLayouts(result.atlasLayouts)
            if result.success {
                sessionStore.updateSessionAtlasRegion(
                    streamID: result.targetSlotStreamID,
                    atlasRegion: result.atlasRegion
                )
            }
            if result.success {
                MirageLogger.client(
                    "App window swap succeeded: stream=\(result.targetSlotStreamID), window=\(result.windowID)"
                )
            } else {
                MirageLogger.client(
                    "App window swap failed: stream=\(result.targetSlotStreamID), window=\(result.windowID), reason=\(result.reason ?? "unknown")"
                )
            }
            onAppWindowSwapResult?(result)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app window swap result: ")
        }
    }

    /// Forwards the result of a user action taken from a close-blocked app-window alert.
    func handleAppWindowCloseAlertActionResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(AppWindowCloseAlertActionResultMessage.self)
            onAppWindowCloseAlertActionResult?(result)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app-window close alert action result: ")
        }
    }

    /// Clears active app-stream state when the streamed host app terminates.
    func handleAppTerminated(_ message: ControlMessage) {
        do {
            let terminated = try message.decode(AppTerminatedMessage.self)
            MirageLogger.client("App terminated: \(terminated.bundleIdentifier)")
            if streamingAppBundleID == terminated.bundleIdentifier {
                streamingAppBundleID = nil
                appWindowInventory = nil
                pendingAppRequestedColorDepth = nil
                pendingAppRequestedLatencyMode = nil
            }
            onAppTerminated?(terminated)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode app terminated: ")
        }
    }

    /// Applies host runtime stream policies to the session store and active controllers.
    func handleStreamPolicyUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(StreamPolicyUpdateMessage.self)
            sessionStore.applyHostStreamPolicies(update.policies)
            Task { [weak self] in
                guard let self else { return }
                await applyHostStreamPolicies(update.policies, epoch: update.epoch)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode stream policy update: ")
        }
    }
}
