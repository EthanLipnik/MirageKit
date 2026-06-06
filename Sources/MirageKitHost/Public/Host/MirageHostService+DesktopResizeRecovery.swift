//
//  MirageHostService+DesktopResizeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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
import CoreGraphics
import Foundation

#if os(macOS)

extension MirageHostService {
    /// Recovers a failed desktop resize by rolling back, falling back to main display capture, or stopping the stream.
    func handleDesktopResizeFailure(
        _ resizeError: Error,
        streamID: StreamID,
        request: DesktopResizeRequestState,
        preResizeSnapshot: MirageHostVirtualDisplaySnapshot?,
        latestShouldRestoreMirroring shouldRestoreMirroring: Bool,
        previousRequestedDisplayScaleFactor: CGFloat?,
        previousRequestedStreamScale: CGFloat,
        previousEncoderMaxDimensions: (width: Int?, height: Int?)
    )
    async -> DesktopResizeFailureHandlingResult {
        var completionContext: StreamContext?
        var outcome: MirageWire.MirageDesktopTransitionOutcome = .resized
        var shouldStopStreamWithError = false
        var shouldRestoreMirroring = shouldRestoreMirroring

        if streamID == desktopStreamID,
           let latestDesktopContext = desktopStreamContext {
            switch desktopResizeFailureRecoveryPlan(
                desktopStreamMode: desktopStreamMode,
                hasPreResizeSnapshot: preResizeSnapshot != nil
            ) {
            case .rollbackToLastKnownGood:
                MirageLogger.error(.host, error: resizeError, message: "Failed to resize desktop stream: ")
                if let preResizeSnapshot {
                    do {
                        let restoredContext = try await rollbackDesktopResolutionChange(
                            streamID: streamID,
                            request: request,
                            snapshot: preResizeSnapshot,
                            context: latestDesktopContext,
                            requestedDisplayScaleFactor: previousRequestedDisplayScaleFactor,
                            requestedStreamScale: previousRequestedStreamScale,
                            encoderMaxWidth: previousEncoderMaxDimensions.width,
                            encoderMaxHeight: previousEncoderMaxDimensions.height
                        )
                        completionContext = restoredContext
                        outcome = .rolledBack
                        if shouldRestoreMirroring,
                           desktopResizeRequiresMirroringRestoreSuccess(desktopStreamMode: desktopStreamMode),
                           let restoredSnapshot = await platformVirtualDisplayBackend.displaySnapshot {
                            let mirroringRestored = await restoreDisplayMirroringAfterResize(
                                streamID: streamID,
                                targetDisplayID: restoredSnapshot.displayID,
                                expectedPixelResolution: restoredSnapshot.resolution
                            )
                            if !mirroringRestored {
                                throw MirageCore.MirageError.protocolError(
                                    "Unified desktop resize rollback could not restore display mirroring"
                                )
                            }
                            shouldRestoreMirroring = false
                        }
                    } catch {
                        MirageLogger.error(
                            .host,
                            error: error,
                            message: "Failed to roll back desktop resize to the last known good resolution: "
                        )
                        shouldStopStreamWithError = true
                    }
                } else {
                    shouldStopStreamWithError = true
                }
            case .mainDisplayFallback:
                do {
                    let fallbackContext = try await switchDesktopStreamToMainDisplayFallback(
                        streamID: streamID,
                        request: request,
                        context: latestDesktopContext,
                        reason: "desktop_resize_failed"
                    )
                    completionContext = fallbackContext
                    outcome = .rolledBack
                    shouldRestoreMirroring = false
                } catch {
                    MirageLogger.host("Main display fallback after desktop resize failure was unavailable: \(error)")
                    MirageLogger.error(.host, error: resizeError, message: "Failed to resize desktop stream: ")
                    shouldStopStreamWithError = true
                }
            case .stopStream:
                MirageLogger.error(.host, error: resizeError, message: "Failed to resize desktop stream: ")
                shouldStopStreamWithError = true
            }
        } else {
            MirageLogger.error(.host, error: resizeError, message: "Failed to resize desktop stream: ")
            shouldStopStreamWithError = streamID == desktopStreamID
        }

        return DesktopResizeFailureHandlingResult(
            completionContext: completionContext,
            outcome: outcome,
            shouldStopStreamWithError: shouldStopStreamWithError,
            shouldRestoreMirroring: shouldRestoreMirroring
        )
    }

    /// Restores the previous desktop virtual-display resolution after a failed resize.
    func rollbackDesktopResolutionChange(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        snapshot: MirageHostVirtualDisplaySnapshot,
        context: StreamContext,
        requestedDisplayScaleFactor: CGFloat?,
        requestedStreamScale: CGFloat,
        encoderMaxWidth: Int?,
        encoderMaxHeight: Int?
    )
    async throws -> StreamContext {
        let refreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: Int(snapshot.refreshRate.rounded()))
        let rollbackRequest = desktopVirtualDisplayResizeRequest(
            pixelResolution: snapshot.resolution,
            refreshRate: refreshRate,
            hiDPI: snapshot.scaleFactor > 1.5,
            colorSpace: snapshot.colorSpace
        )
        var updateResult = try await platformVirtualDisplayBackend.updateDisplayResolution(
            for: .desktopStream,
            newResolution: snapshot.resolution,
            refreshRate: refreshRate,
            resizeRequest: MirageHostVirtualDisplayResizeRequest(resizeRequest: rollbackRequest),
            allowRecreation: false
        )
        if updateResult.outcome == .requiresRecreation {
            updateResult = try await platformVirtualDisplayBackend.updateDisplayResolution(
                for: .desktopStream,
                newResolution: snapshot.resolution,
                refreshRate: refreshRate,
                resizeRequest: MirageHostVirtualDisplayResizeRequest(resizeRequest: rollbackRequest),
                allowRecreation: true
            )
        }

        guard let restoredSnapshot = await platformVirtualDisplayBackend.displaySnapshot else {
            throw MirageCore.MirageError.protocolError("Missing shared display snapshot after desktop resize rollback")
        }

        sharedVirtualDisplayScaleFactor = max(1.0, restoredSnapshot.scaleFactor)
        sharedVirtualDisplayGeneration = restoredSnapshot.generation
        desktopVirtualDisplayID = restoredSnapshot.displayID
        desktopRequestedScaleFactor = max(1.0, requestedDisplayScaleFactor ?? restoredSnapshot.scaleFactor)
        await context.updateDesktopResizeGeometryRequest(
            requestedStreamScale: requestedStreamScale,
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )

        let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6)
        try await context.hardResetDesktopDisplayCapture(
            displayWrapper: captureDisplay,
            resolution: restoredSnapshot.resolution
        )
        if captureDisplay.display.displayID != restoredSnapshot.displayID {
            MirageLogger
                .host(
                    "Desktop resize rollback captured display \(captureDisplay.display.displayID) while shared display is \(restoredSnapshot.displayID)"
                )
        }

        let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputGeometry = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: primaryBounds,
            virtualResolution: restoredSnapshot.resolution
        )
        wakeAndCenterVirtualDisplaySetupCursor(reason: "desktop_resize_rollback")

        let outcomeLabel = switch updateResult.outcome {
        case .noChange:
            "no-change"
        case .updatedInPlace:
            "updated-in-place"
        case .requiresRecreation:
            "requires-recreation"
        case .recreated:
            "recreated"
        }
        MirageLogger
            .host(
                "Rolled back desktop resize transition \(request.transitionID?.uuidString ?? "nil") to " +
                    "\(Int(restoredSnapshot.resolution.width))x\(Int(restoredSnapshot.resolution.height)) px " +
                    "(outcome: \(outcomeLabel), input bounds: \(inputGeometry.inputBounds))"
            )

        return context
    }

    /// Switches desktop capture from the virtual display to the main physical display.
    func switchDesktopStreamToMainDisplayFallback(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        context: StreamContext,
        reason: String
    )
    async throws -> StreamContext {
        try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
        let fallback = try await mainDisplayDesktopCaptureFallback(reason: reason)

        if let sharedDisplayID = await platformVirtualDisplayBackend.displayID {
            _ = await disableDisplayMirroring(displayID: sharedDisplayID)
        } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
            _ = await disableDisplayMirroring(displayID: fallback.displayID)
        }
        await platformVirtualDisplayBackend.releaseDisplayForConsumer(.desktopStream)

        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = fallback.displayID
        desktopPrimaryPhysicalBounds = fallback.bounds
        desktopDisplayBounds = fallback.bounds
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = fallback.scaleFactor
        desktopUsesHostResolution = true
        desktopCaptureSource = .mainDisplayFallback

        if desktopStreamMode == .unified {
            let mirroringConfigured = await setupDisplayMirroring(
                targetDisplayID: fallback.displayID,
                expectedPixelResolution: fallback.resolution,
                requiresResidualMirageDisplaysClear: false
            )
            if !mirroringConfigured {
                MirageLogger.host(
                    "Desktop stream main display fallback continuing with incomplete display mirroring"
                )
            }
        }

        try await context.hardResetDesktopDisplayCapture(
            displayWrapper: fallback.display,
            resolution: fallback.resolution
        )

        let inputGeometry = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: fallback.bounds,
            virtualResolution: fallback.resolution
        )
        MirageLogger.host(
            "Desktop stream switched to main display fallback for stream \(streamID): " +
                "\(Int(fallback.resolution.width))x\(Int(fallback.resolution.height)) px " +
                "(input bounds: \(inputGeometry.inputBounds))"
        )
        return context
    }

    /// Sends the host-authoritative desktop resize completion message to the active client.
    func sendDesktopResizeCompletion(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        context: StreamContext,
        outcome: MirageWire.MirageDesktopTransitionOutcome
    )
    async {
        guard let clientContext = desktopStreamClientContext else { return }
        guard let desktopSessionID else {
            MirageLogger.error(.host, "Missing desktop session ID for resize completion on stream \(streamID)")
            return
        }

        let streamStartSnapshot = await context.streamStartSnapshot
        let dimensionToken = streamStartSnapshot.dimensionToken
        let encodedDimensions = streamStartSnapshot.encodedDimensions
        let encodedResolution = CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
        let updatedTargetFrameRate = streamStartSnapshot.targetFrameRate
        let displayResolution = await currentDesktopStartedResolution(
            fallback: CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
        )
        let acceptedDisplayScaleFactor = desktopRequestedScaleFactor ?? sharedVirtualDisplayScaleFactor
        let geometryContract: DesktopGeometryAnnouncementContract
        if outcome == .rolledBack {
            if desktopCaptureSource == .mainDisplayFallback {
                let presentationResolution = aspectFitPixelSize(
                    contentSize: displayResolution,
                    containerSize: request.logicalResolution
                )
                geometryContract = DesktopGeometryAnnouncementContract(
                    contractID: nil,
                    sceneIdentity: nil,
                    presentationResolution: presentationResolution,
                    displayPixelResolution: displayResolution,
                    encodedPixelResolution: encodedResolution,
                    acceptedDisplayScaleFactor: acceptedDisplayScaleFactor,
                    refreshTargetHz: updatedTargetFrameRate
                )
            } else {
                geometryContract = reusableCurrentDesktopGeometryContract(
                    displayPixelResolution: displayResolution,
                    encodedPixelResolution: encodedResolution,
                    refreshTargetHz: updatedTargetFrameRate
                )
            }
        } else {
            geometryContract = DesktopGeometryAnnouncementContract(
                contractID: request.desktopGeometryContractID,
                sceneIdentity: request.desktopGeometrySceneIdentity,
                presentationResolution: request.logicalResolution,
                displayPixelResolution: displayResolution,
                encodedPixelResolution: encodedResolution,
                acceptedDisplayScaleFactor: acceptedDisplayScaleFactor,
                refreshTargetHz: request.desktopGeometryRefreshTargetHz ?? updatedTargetFrameRate
            )
        }
        let codec = streamStartSnapshot.codec
        let acceptedMediaMaxPacketSize = streamStartSnapshot.mediaMaxPacketSize
        desktopPresentationGeneration &+= 1
        let message = MirageWire.DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(displayResolution.width),
            height: Int(displayResolution.height),
            frameRate: updatedTargetFrameRate,
            codec: codec,
            displayCount: 1,
            dimensionToken: dimensionToken,
            acceptedMediaMaxPacketSize: acceptedMediaMaxPacketSize,
            transitionID: request.transitionID,
            transitionPhase: .resize,
            transitionOutcome: outcome,
            desktopPresentationGeneration: desktopPresentationGeneration,
            captureSource: desktopCaptureSource,
            allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
            acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
            presentationWidth: Int(geometryContract.presentationResolution.width.rounded()),
            presentationHeight: Int(geometryContract.presentationResolution.height.rounded()),
            desktopGeometryContractID: geometryContract.contractID,
            desktopGeometrySceneIdentity: geometryContract.sceneIdentity,
            desktopGeometryDisplayPixelWidth: Int(geometryContract.displayPixelResolution.width.rounded()),
            desktopGeometryDisplayPixelHeight: Int(geometryContract.displayPixelResolution.height.rounded()),
            desktopGeometryEncodedPixelWidth: Int(geometryContract.encodedPixelResolution.width.rounded()),
            desktopGeometryEncodedPixelHeight: Int(geometryContract.encodedPixelResolution.height.rounded()),
            desktopGeometryRefreshTargetHz: geometryContract.refreshTargetHz ?? updatedTargetFrameRate
        )
        if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            MirageLogger.error(.host, "Failed to encode desktop resize completion for stream \(streamID)")
            return
        }
        if geometryContract.contractID == nil {
            clearCurrentDesktopGeometryContract()
        } else {
            recordCurrentDesktopGeometryContract(
                contractID: geometryContract.contractID,
                sceneIdentity: geometryContract.sceneIdentity,
                presentationResolution: geometryContract.presentationResolution,
                displayPixelResolution: geometryContract.displayPixelResolution,
                encodedPixelResolution: geometryContract.encodedPixelResolution,
                acceptedDisplayScaleFactor: geometryContract.acceptedDisplayScaleFactor,
                refreshTargetHz: geometryContract.refreshTargetHz
            )
        }
        MirageLogger.host(
            "Sent desktop resize completion for stream \(streamID) " +
                "(transition=\(request.transitionID?.uuidString ?? "nil"), outcome=\(outcome.rawValue))"
        )
    }

    /// Logs whether the resized desktop display and encoder pipeline still match color expectations.
    func logDesktopResizeColorPipelineValidation(
        streamID: StreamID,
        displaySnapshot: MirageHostVirtualDisplaySnapshot,
        context: StreamContext
    )
    async {
        let settings = await context.encoderSettings
        let runtime = await context.encoder?.runtimeValidationSnapshot

        let colorValidation = platformVirtualDisplayBackend.displayColorSpaceValidation(
            displayID: displaySnapshot.displayID,
            expectedColorSpace: settings.colorSpace
        )
        let displayCoverageStatus = colorValidation.coverageStatus
        let displayColorMatches = displayCoverageStatus == .strictCanonical || displayCoverageStatus == .wideGamutEquivalent
        let measuredEquivalentCoverage = displayCoverageStatus == .wideGamutEquivalent
        let displayColorObserved = colorValidation.observedName ?? "unknown"
        let runtimePixelFormat = runtime?.pixelFormat.displayName ?? settings.pixelFormat.displayName
        let runtimeProfile = runtime?.profileName ?? "unknown"
        let runtimePrimaries = runtime?.colorPrimaries ?? "unknown"
        let runtimeTransfer = runtime?.transferFunction ?? "unknown"
        let runtimeMatrix = runtime?.yCbCrMatrix ?? "unknown"
        let runtimeDisplayP3Validated = runtime?.tenBitDisplayP3Validated == true || runtime?.ultra444Validated == true
        let expectsTenBitDisplayP3 = settings.bitDepth == .tenBit && settings.colorSpace == .displayP3
        let displayColorStatus = displayCoverageStatus.rawValue

        if expectsTenBitDisplayP3, displayColorMatches, runtimeDisplayP3Validated {
            let coverageLabel = measuredEquivalentCoverage ? "measured-equivalent" : "canonical"
            MirageLogger.host(
                "Desktop resize validation passed for stream \(streamID): display=\(displaySnapshot.displayID) color=\(displayColorObserved), encoder=\(runtimePixelFormat), profile=\(runtimeProfile), target=Display P3 10-bit (\(coverageLabel))"
            )
            return
        }

        let message =
            "Desktop resize validation status=\(displayColorStatus) for stream \(streamID): " +
            "display=\(displaySnapshot.displayID), expectedColor=\(settings.colorSpace.displayName), observedColor=\(displayColorObserved), " +
            "encoderPixelFormat=\(runtimePixelFormat), encoderProfile=\(runtimeProfile), " +
            "encoderPrimaries=\(runtimePrimaries), encoderTransfer=\(runtimeTransfer), encoderMatrix=\(runtimeMatrix), " +
            "tenBitDisplayP3Validated=\(runtimeDisplayP3Validated)"

        if expectsTenBitDisplayP3 {
            MirageLogger.error(.host, message)
        } else {
            MirageLogger.host(message)
        }
    }
}

#endif
