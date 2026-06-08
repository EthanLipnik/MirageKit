//
//  MirageClientService+DesktopResizeMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import MirageKit

@MainActor
extension MirageClientService {
    /// Applies a host-confirmed desktop resize transition to local stream state and decoder setup.
    func handleDesktopResizeCommit(_ started: DesktopStreamStartedMessage) async -> Bool {
        let streamID = started.streamID
        var matchesActiveTransition = false
        var matchesGenerationContract = false
        var matchesPreservedTransition = false
        guard desktopSessionID == started.desktopSessionID else {
            MirageLogger.client(
                "Ignoring stale desktop resize commit for stream \(streamID): session=\(started.desktopSessionID.uuidString)"
            )
            return false
        }
        if let acceptedContractID = started.desktopGeometryContractID {
            let activeTransition = desktopResizeCoordinator.activeTransition
            let activeTransitionRejectionReason: String? = if let activeTransition = desktopResizeCoordinator.activeTransition {
                if activeTransition.streamID == streamID {
                    if desktopResizeCoordinator.acceptTransition(
                        streamID: streamID,
                        transitionID: started.transitionID
                    ) {
                        activeTransition.target.acceptedGeometryRejectionReason(
                            acceptedContractID: acceptedContractID,
                            acceptedSceneIdentity: started.desktopGeometrySceneIdentity
                        )
                    } else {
                        "transition=\(started.transitionID?.uuidString ?? "nil") expected=\(activeTransition.transitionID.uuidString)"
                    }
                } else {
                    "activeTransitionStream=\(activeTransition.streamID)"
                }
            } else {
                "activeTransition=nil"
            }
            let generationContractRejectionReason: String? = if started.desktopPresentationGeneration != nil,
                                                                let lastSentTarget = desktopResizeCoordinator.lastSentTarget {
                lastSentTarget.acceptedGeometryRejectionReason(
                    acceptedContractID: acceptedContractID,
                    acceptedSceneIdentity: started.desktopGeometrySceneIdentity
                )
            } else {
                "generationContract=unavailable"
            }
            let preservedTransitionRejectionReason: String? = if activeTransition == nil,
                                                                 let lastSentTransition = desktopResizeCoordinator.lastSentTransition {
                if lastSentTransition.streamID == streamID {
                    if started.transitionID == lastSentTransition.transitionID {
                        lastSentTransition.target.acceptedGeometryRejectionReason(
                            acceptedContractID: acceptedContractID,
                            acceptedSceneIdentity: started.desktopGeometrySceneIdentity
                        )
                    } else {
                        "transition=\(started.transitionID?.uuidString ?? "nil") expected=\(lastSentTransition.transitionID.uuidString)"
                    }
                } else {
                    "lastSentTransitionStream=\(lastSentTransition.streamID)"
                }
            } else if activeTransition == nil {
                "lastSentTransition=unavailable"
            } else {
                "activeTransition=present"
            }
            matchesActiveTransition = activeTransitionRejectionReason == nil
            matchesGenerationContract = activeTransition == nil &&
                generationContractRejectionReason == nil
            matchesPreservedTransition = preservedTransitionRejectionReason == nil
            guard matchesActiveTransition || matchesGenerationContract || matchesPreservedTransition else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): " +
                        "geometryContract=\(acceptedContractID.uuidString) " +
                        "active=\(activeTransitionRejectionReason ?? "ok") " +
                        "generation=\(generationContractRejectionReason ?? "ok") " +
                        "preserved=\(preservedTransitionRejectionReason ?? "ok")"
                )
                return false
            }
        } else if let activeTransition = desktopResizeCoordinator.activeTransition,
                  activeTransition.streamID == streamID {
            let transitionMatches = desktopResizeCoordinator.acceptTransition(
                streamID: streamID,
                transitionID: started.transitionID
            )
            let isHostAuthoritativeRollback = started.captureSource == .mainDisplayFallback &&
                started.allowsClientResize == false &&
                started.transitionOutcome == .rolledBack
            matchesActiveTransition = transitionMatches
            guard matchesActiveTransition || isHostAuthoritativeRollback else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): " +
                        "missing geometry contract while active transition=\(activeTransition.transitionID.uuidString) " +
                        "startedTransition=\(started.transitionID?.uuidString ?? "nil")"
                )
                return false
            }
        }
        if let generation = started.desktopPresentationGeneration {
            let previousGeneration = desktopPresentationGenerationBySessionID[started.desktopSessionID] ?? 0
            guard generation > previousGeneration || matchesActiveTransition || matchesPreservedTransition else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): generation=\(generation) previous=\(previousGeneration)"
                )
                return false
            }
        } else {
            guard matchesActiveTransition || matchesPreservedTransition || desktopResizeCoordinator.acceptTransition(
                    streamID: streamID,
                    transitionID: started.transitionID
                ) else {
                MirageLogger.client(
                    "Ignoring stale desktop resize commit for stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
                )
                return false
            }
        }

        guard desktopStreamID == streamID || controllersByStream[streamID] != nil else {
            MirageLogger.client(
                "Ignoring desktop resize commit for inactive stream \(streamID): transition=\(started.transitionID?.uuidString ?? "nil")"
            )
            clearDesktopResizeState(streamID: streamID)
            return false
        }

        desktopStreamID = streamID
        let encodedSize = CGSize(width: started.width, height: started.height)
        desktopStreamResolution = encodedSize
        let presentationSize = started.presentationSize
        desktopStreamPresentationResolution = presentationSize
        let acceptedDisplayPixelSize = acceptedDesktopDisplayPixelSize(from: started)
        desktopStreamDisplayScaleFactor = acceptedDesktopDisplayScaleFactor(
            from: started,
            displayPixelSize: acceptedDisplayPixelSize,
            presentationSize: presentationSize
        )
        desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedStreamGeometry(
            logicalResolution: presentationSize,
            displayPixelSize: acceptedDisplayPixelSize
        )
        desktopResizeCoordinator.clearQueuedTargetsMatchingAcceptedDisplayPixels(acceptedDisplayPixelSize)
        desktopCaptureSource = started.captureSource
        desktopStreamAllowsClientResize = started.allowsClientResize
        updateObservedFrameRate(started.frameRate, for: streamID)
        if let generation = started.desktopPresentationGeneration {
            let previousGeneration = desktopPresentationGenerationBySessionID[started.desktopSessionID] ?? 0
            if generation > previousGeneration || matchesGenerationContract {
                desktopPresentationGenerationBySessionID[started.desktopSessionID] = generation
            }
        }
        activeStreamCodecs[streamID] = started.codec
        if let dimensionToken = started.dimensionToken {
            desktopDimensionTokenByStream[streamID] = dimensionToken
        }

        let desktopMinSize = presentationSize
        sessionStore.updateMinimumSize(for: streamID, minSize: desktopMinSize)
        onStreamMinimumSizeUpdate?(streamID, desktopMinSize)
        onDesktopStreamStarted?(streamID, desktopMinSize, started.displayCount)

        let outcome = started.transitionOutcome ?? .resized
        if outcome == .noChange {
            postResizeTransitionTimeoutTasks[streamID]?.cancel()
            postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
            sessionStore.clearPostResizeTransition(for: streamID)
            desktopResizeCoordinator.finishTransition()
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            return true
        }

        if started.allowsClientResize {
            beginPostResizeTransition(streamID: streamID, scheduleTimeout: false)
        } else {
            sessionStore.clearPostResizeTransition(for: streamID)
        }
        await applyStreamCadenceTarget(
            started.frameRate,
            for: streamID,
            reason: "desktop resize commit"
        )
        await prepareControllerForDesktopResize(
            streamID,
            codec: started.codec,
            streamDimensions: (width: started.width, height: started.height),
            mediaMaxPacketSize: started.acceptedMediaMaxPacketSize,
            dimensionToken: started.dimensionToken,
            targetFrameRate: started.frameRate
        )
        desktopResizeCoordinator.finishTransition()
        if !started.allowsClientResize {
            desktopResizeCoordinator.clearAllState()
            sessionStore.clearPostResizeTransition(for: streamID)
        } else {
            schedulePostResizeTransitionTimeoutIfNeeded(streamID: streamID)
        }
        return true
    }
}
