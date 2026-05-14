//
//  MirageHostService+DesktopResizeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

extension MirageHostService {
    /// Recovers a failed desktop resize by rolling back to the previous virtual display or stopping the stream.
    func handleDesktopResizeFailure(
        _ resizeError: Error,
        streamID: StreamID,
        request: DesktopResizeRequestState,
        preResizeSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
        latestShouldRestoreMirroring shouldRestoreMirroring: Bool,
        previousRequestedDisplayScaleFactor: CGFloat?,
        previousRequestedStreamScale: CGFloat,
        previousEncoderMaxDimensions: (width: Int?, height: Int?)
    )
    async -> DesktopResizeFailureHandlingResult {
        var completionContext: StreamContext?
        var outcome: MirageDesktopTransitionOutcome = .resized
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
                           let restoredSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot {
                            let mirroringRestored = await restoreDisplayMirroringAfterResize(
                                streamID: streamID,
                                targetDisplayID: restoredSnapshot.displayID,
                                expectedPixelResolution: restoredSnapshot.resolution
                            )
                            if !mirroringRestored {
                                throw MirageError.protocolError(
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
        snapshot: SharedVirtualDisplayManager.DisplaySnapshot,
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
        var updateResult = try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
            for: .desktopStream,
            newResolution: snapshot.resolution,
            refreshRate: refreshRate,
            resizeRequest: rollbackRequest,
            allowRecreation: false
        )
        if updateResult.outcome == .requiresRecreation {
            updateResult = try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                for: .desktopStream,
                newResolution: snapshot.resolution,
                refreshRate: refreshRate,
                resizeRequest: rollbackRequest,
                allowRecreation: true
            )
        }

        guard let restoredSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot else {
            throw MirageError.protocolError("Missing shared display snapshot after desktop resize rollback")
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

    /// Sends the host-authoritative desktop resize completion message to the active client.
    func sendDesktopResizeCompletion(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        context: StreamContext,
        outcome: MirageDesktopTransitionOutcome
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
        let displayResolution = await currentDesktopStartedResolution(
            fallback: CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
        )
        let presentationResolution: CGSize = if desktopCaptureSource == .mainDisplayFallback {
            aspectFitPixelSize(
                contentSize: displayResolution,
                containerSize: virtualDisplayPixelResolution(
                    for: request.logicalResolution,
                    scaleFactorOverride: desktopRequestedScaleFactor
                )
            )
        } else {
            displayResolution
        }
        let updatedTargetFrameRate = streamStartSnapshot.targetFrameRate
        let codec = streamStartSnapshot.codec
        let acceptedMediaMaxPacketSize = streamStartSnapshot.mediaMaxPacketSize
        desktopPresentationGeneration &+= 1
        let message = DesktopStreamStartedMessage(
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
            presentationWidth: Int(presentationResolution.width.rounded()),
            presentationHeight: Int(presentationResolution.height.rounded())
        )
        if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
            MirageLogger.error(.host, "Failed to encode desktop resize completion for stream \(streamID)")
            return
        }
        MirageLogger.host(
            "Sent desktop resize completion for stream \(streamID) " +
                "(transition=\(request.transitionID?.uuidString ?? "nil"), outcome=\(outcome.rawValue))"
        )
    }

    /// Logs whether the resized desktop display and encoder pipeline still match color expectations.
    func logDesktopResizeColorPipelineValidation(
        streamID: StreamID,
        displaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        context: StreamContext
    )
    async {
        let settings = await context.encoderSettings
        let runtime = await context.encoder?.runtimeValidationSnapshot

        let colorValidation = CGVirtualDisplayBridge.displayColorSpaceValidation(
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
