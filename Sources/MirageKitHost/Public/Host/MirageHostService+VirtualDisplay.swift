//
//  MirageHostService+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/11/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

extension MirageHostService {
    /// Clears queued and active desktop resize transaction state.
    func resetDesktopResizeTransactionState() {
        activeDesktopResizeRequest = nil
        queuedDesktopResizeRequest = nil
        desktopResizeTransactionState = .idle
        desktopPresentationGeneration = 0
    }

    /// Coalesces desktop resize requests and applies the latest queued resolution.
    func enqueueDesktopResolutionChange(
        streamID: StreamID,
        request: DesktopResizeRequestState
    )
    async {
        guard streamID == desktopStreamID else { return }

        queuedDesktopResizeRequest = request
        let transitionIDText = request.transitionID?.uuidString ?? "nil"
        MirageLogger
            .host(
                "Queued desktop resize request: " +
                    "\(Int(request.logicalResolution.width))x\(Int(request.logicalResolution.height)) pts" +
                    " transition=\(transitionIDText)"
            )

        guard activeDesktopResizeRequest == nil else { return }
        beginDesktopSharedDisplayTransition()
        defer {
            activeDesktopResizeRequest = nil
            queuedDesktopResizeRequest = nil
            endDesktopSharedDisplayTransition()
        }

        while let nextRequest = queuedDesktopResizeRequest {
            queuedDesktopResizeRequest = nil
            activeDesktopResizeRequest = nextRequest
            desktopResizeTransactionState = .applying(nextRequest)
            await applyDesktopResolutionChange(
                streamID: streamID,
                request: nextRequest
            )
            if activeDesktopResizeRequest == nextRequest {
                activeDesktopResizeRequest = nil
            }

            guard desktopStreamID == streamID, desktopStreamContext != nil else {
                queuedDesktopResizeRequest = nil
                activeDesktopResizeRequest = nil
                return
            }
        }
    }

    /// Applies one desktop resize request to the shared virtual display and capture state.
    private func applyDesktopResolutionChange(
        streamID: StreamID,
        request: DesktopResizeRequestState
    )
    async {
        guard streamID == desktopStreamID, let desktopContext = desktopStreamContext else { return }
        var virtualDisplaySetupGuardToken: UUID?
        defer {
            if let token = virtualDisplaySetupGuardToken {
                Task { @MainActor [weak self] in
                    await self?.cancelVirtualDisplaySetupGuard(
                        token,
                        reason: "desktop_resize_aborted"
                    )
                }
            }
        }

        let mirroringPlan = desktopResizeMirroringPlan(for: desktopStreamMode)
        var suspendedMirroringDisplayID: CGDirectDisplayID?
        var shouldRestoreMirroring = false
        var resizeCompletionContext: StreamContext?
        var shouldStopDesktopStreamWithError = false
        var shouldResumeEncodingAfterResize = false
        var preResizeSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
        var resizeOutcome: MirageDesktopTransitionOutcome = .resized
        let previousRequestedDisplayScaleFactor = desktopRequestedScaleFactor
        let previousRequestedStreamScale = await desktopContext.requestedStreamScale
        let previousEncoderMaxDimensions = await desktopContext.encoderMaxDimensions
        do {
            preResizeSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
            let geometry = await resolvedDesktopResizeGeometry(
                request: request,
                context: desktopContext,
                preResizeSnapshot: preResizeSnapshot
            )
            let currentEncodedDimensions = await desktopContext.encodedDimensions
            let currentEncodedResolution = CGSize(
                width: currentEncodedDimensions.width,
                height: currentEncodedDimensions.height
            )
            let requestedColorSpace = preResizeSnapshot?.colorSpace ?? .sRGB
            let resizeRequest = desktopVirtualDisplayResizeRequest(
                pixelResolution: geometry.pixelResolution,
                refreshRate: geometry.refreshRate,
                hiDPI: geometry.requestedDisplayScaleFactor > 1.5,
                colorSpace: requestedColorSpace
            )
            let noOpDecision = desktopResizeNoOpDecision(
                currentResolution: preResizeSnapshot?.resolution,
                currentRefreshRate: preResizeSnapshot.map { Int($0.refreshRate.rounded()) },
                currentEncodedResolution: currentEncodedResolution,
                requestedResolution: geometry.pixelResolution,
                requestedRefreshRate: geometry.refreshRate,
                requestedEncodedResolution: geometry.encodedResolution
            )
            let logContext = DesktopResizeLogContext(
                transitionIDText: request.transitionID?.uuidString ?? "nil",
                logicalResolutionText: "\(Int(geometry.logicalResolution.width))x\(Int(geometry.logicalResolution.height)) pts",
                pixelResolutionText: "\(Int(geometry.pixelResolution.width))x\(Int(geometry.pixelResolution.height)) px",
                encodedResolutionText: "\(Int(geometry.encodedResolution.width))x\(Int(geometry.encodedResolution.height)) px"
            )
            if noOpDecision == .noOp {
                try await completeNoOpDesktopResize(
                    streamID: streamID,
                    request: request,
                    context: desktopContext,
                    geometry: geometry,
                    logContext: logContext
                )
                return
            }

            MirageLogger
                .host(
                    "Desktop stream resize requested: " +
                        "\(logContext.logicalResolutionText) " +
                        "(\(logContext.pixelResolutionText), " +
                        "encoded \(logContext.encodedResolutionText), " +
                        "transition=\(logContext.transitionIDText))"
                )
            virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
                reason: "desktop_resize"
            )
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
            await desktopContext.suspendEncodingForDesktopResize()
            shouldResumeEncodingAfterResize = true
            await desktopContext.updateDesktopResizeGeometryRequest(
                requestedStreamScale: geometry.requestedStreamScale,
                encoderMaxWidth: geometry.encoderMaxWidth,
                encoderMaxHeight: geometry.encoderMaxHeight
            )
            desktopRequestedScaleFactor = geometry.requestedDisplayScaleFactor

            let requiresDisplayReconfigure =
                preResizeSnapshot?.resolution != geometry.pixelResolution ||
                preResizeSnapshot.map { Int($0.refreshRate.rounded()) } != geometry.refreshRate
            if !requiresDisplayReconfigure {
                virtualDisplaySetupGuardToken = try await completeEncodedOnlyDesktopResize(
                    streamID: streamID,
                    request: request,
                    context: desktopContext,
                    geometry: geometry,
                    logContext: logContext,
                    setupGuardToken: virtualDisplaySetupGuardToken
                )
                resizeCompletionContext = desktopContext
                resizeOutcome = .resized
            } else {
                resizeCompletionContext = try await reconfigureDesktopDisplayForResize(
                    streamID: streamID,
                    request: request,
                    geometry: geometry,
                    resizeRequest: resizeRequest,
                    mirroringPlan: mirroringPlan,
                    preResizeSnapshot: preResizeSnapshot,
                    setupGuardToken: &virtualDisplaySetupGuardToken,
                    shouldRestoreMirroring: &shouldRestoreMirroring,
                    suspendedMirroringDisplayID: &suspendedMirroringDisplayID,
                    logContext: logContext
                )
                resizeOutcome = .resized
            }
        } catch DesktopResizeTransactionAbort.streamNoLongerActive {
            MirageLogger.host(
                "Desktop resize transaction aborted because stream is no longer active " +
                    "(transition=\(request.transitionID?.uuidString ?? "nil"))"
            )
            desktopResizeTransactionState = .failed(request)
            return
        } catch {
            let result = await handleDesktopResizeFailure(
                error,
                streamID: streamID,
                request: request,
                preResizeSnapshot: preResizeSnapshot,
                latestShouldRestoreMirroring: shouldRestoreMirroring,
                previousRequestedDisplayScaleFactor: previousRequestedDisplayScaleFactor,
                previousRequestedStreamScale: previousRequestedStreamScale,
                previousEncoderMaxDimensions: previousEncoderMaxDimensions
            )
            resizeCompletionContext = result.completionContext
            resizeOutcome = result.outcome
            shouldStopDesktopStreamWithError = result.shouldStopStreamWithError
            shouldRestoreMirroring = result.shouldRestoreMirroring
        }

        if shouldRestoreMirroring {
            let restoreSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
            let restoreDisplayID = restoreSnapshot?.displayID ?? suspendedMirroringDisplayID
            if let restoreDisplayID {
                if shouldStopDesktopStreamWithError {
                    _ = await disableDisplayMirroring(displayID: restoreDisplayID)
                } else if streamID == desktopStreamID, desktopStreamMode == .unified {
                    _ = await setupDisplayMirroring(
                        targetDisplayID: restoreDisplayID,
                        expectedPixelResolution: restoreSnapshot?.resolution
                    )
                } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                    _ = await disableDisplayMirroring(displayID: restoreDisplayID)
                }
            }
        }

        if shouldStopDesktopStreamWithError, streamID == desktopStreamID {
            shouldResumeEncodingAfterResize = false
            await stopDesktopStream(reason: .error)
            return
        }

        guard activeDesktopResizeRequest == request,
              desktopResizeTransactionContinuationDecision(
                  requestedStreamID: streamID,
                  activeDesktopStreamID: desktopStreamID,
                  hasDesktopContext: desktopStreamContext != nil
              ) == .continueTransaction else {
            return
        }

        if let resizeCompletionContext,
           streamID == desktopStreamID {
            await sendDesktopResizeCompletion(
                streamID: streamID,
                request: request,
                context: resizeCompletionContext,
                outcome: resizeOutcome
            )
            if shouldResumeEncodingAfterResize {
                await resizeCompletionContext.resumeEncodingAfterDesktopResize()
                shouldResumeEncodingAfterResize = false
            }
            desktopResizeTransactionState = resizeOutcome == .rolledBack ? .rolledBack(request) : .committed(request)
        }

        if shouldResumeEncodingAfterResize,
           streamID == desktopStreamID,
           let latestDesktopContext = desktopStreamContext {
            await latestDesktopContext.resumeEncodingAfterDesktopResize()
        }
    }

    /// Throws when a desktop resize transaction no longer targets the active stream.
    func ensureDesktopResizeTransactionCanContinue(
        streamID: StreamID,
        request: DesktopResizeRequestState
    )
    throws {
        let continuationDecision = desktopResizeTransactionContinuationDecision(
            requestedStreamID: streamID,
            activeDesktopStreamID: desktopStreamID,
            hasDesktopContext: desktopStreamContext != nil
        )
        guard continuationDecision == .continueTransaction,
              activeDesktopResizeRequest == request else {
            throw DesktopResizeTransactionAbort.streamNoLongerActive
        }
    }
}

#endif
