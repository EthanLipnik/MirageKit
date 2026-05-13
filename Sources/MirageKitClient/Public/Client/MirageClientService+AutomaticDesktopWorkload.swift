//
//  MirageClientService+AutomaticDesktopWorkload.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Client-driven automatic desktop workload reconfiguration.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Requests a host-side desktop workload tier change for the active desktop stream.
    public func requestAutomaticDesktopWorkloadReconfiguration(
        streamID: StreamID,
        target: MirageAutomaticDesktopWorkloadTier
    )
    async throws -> Bool {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard desktopStreamID == streamID else { return false }
        guard pendingLocalDesktopStopStreamID != streamID else { return false }
        guard !startupCriticalSectionActive, !hasActivePostResizeTransition else { return false }
        guard let session = sessionStore.sessionByStreamID(streamID),
              session.hasPresentedFrame,
              session.clientRecoveryStatus == .idle else {
            return false
        }

        let effectiveTarget = Self.runtimeWorkloadSafetyCappedTier(
            target,
            cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
        )
        let snapshot = metricsStore.snapshot(for: streamID)
        let currentFrameRate = snapshot?.hostTargetFrameRate ?? 0
        let needsFrameRateChange = currentFrameRate > 0 && currentFrameRate != effectiveTarget.targetFrameRate
        let currentEncodedSize = CGSize(
            width: snapshot?.hostEncodedWidth ?? 0,
            height: snapshot?.hostEncodedHeight ?? 0
        )
        let hasComparableEncodedSizes = currentEncodedSize.width > 0 &&
            currentEncodedSize.height > 0 &&
            effectiveTarget.encodedPixelSize.width > 0 &&
            effectiveTarget.encodedPixelSize.height > 0
        let encodedSizeMatches = hasComparableEncodedSizes &&
            abs(currentEncodedSize.width - effectiveTarget.encodedPixelSize.width) <= 16 &&
            abs(currentEncodedSize.height - effectiveTarget.encodedPixelSize.height) <= 16
        let needsResize = !encodedSizeMatches
        let allowsAutomaticResolutionResize = desktopStreamMode != .unified && desktopStreamAllowsClientResize
        let decision = Self.automaticDesktopWorkloadReconfigurationDecision(
            needsFrameRateChange: needsFrameRateChange,
            needsResize: needsResize,
            allowsAutomaticResolutionResize: allowsAutomaticResolutionResize
        )

        guard decision.shouldChangeFrameRate || decision.shouldResize else {
            if needsResize && !allowsAutomaticResolutionResize {
                MirageLogger.client(
                    "Skipping automatic desktop workload reconfiguration for stream \(streamID): " +
                        "target \(effectiveTarget.logLabel) requires resize but mode does not allow automatic resize"
                )
            }
            return false
        }

        if decision.shouldChangeFrameRate {
            try await sendStreamEncoderSettingsChange(
                streamID: streamID,
                targetFrameRate: effectiveTarget.targetFrameRate
            )
            refreshRateOverridesByStream[streamID] = effectiveTarget.targetFrameRate
            refreshRateMismatchCounts.removeValue(forKey: streamID)
            refreshRateFallbackTargets.removeValue(forKey: streamID)
        }

        if decision.shouldResize {
            let logicalResolution = automaticDesktopLogicalResolution(
                forEncodedPixelSize: effectiveTarget.encodedPixelSize
            )
            let resizeTarget = desktopResizeTarget(
                for: logicalResolution,
                maxDrawableSize: effectiveTarget.encodedPixelSize
            )
            queueDesktopResize(
                streamID: streamID,
                target: resizeTarget,
                hasPresentedFrame: session.hasPresentedFrame,
                useHostResolution: false,
                dispatchPolicy: .immediate
            )
        }

        MirageLogger.client(
            "Requested automatic desktop workload reconfiguration for stream \(streamID): \(effectiveTarget.logLabel)"
        )
        return true
    }

    /// Converts an automatic workload target's encoded pixel budget into a client-side logical resize.
    ///
    /// The result preserves the current desktop aspect ratio and divides by the active display scale so
    /// the resize request matches the encoded target without stretching the desktop presentation.
    private func automaticDesktopLogicalResolution(forEncodedPixelSize encodedPixelSize: CGSize) -> CGSize {
        let displayScaleFactor = platformDisplayScaleFactor(explicitScaleFactor: nil)
        let sourceSize = desktopStreamPresentationResolution ?? desktopStreamResolution ?? mainDisplayResolution
        let sourceAspect = sourceSize.width > 0 && sourceSize.height > 0 ?
            sourceSize.width / sourceSize.height :
            encodedPixelSize.width / max(1, encodedPixelSize.height)
        let targetAspect = encodedPixelSize.width / max(1, encodedPixelSize.height)
        let fittedPixelSize: CGSize
        if targetAspect > sourceAspect {
            fittedPixelSize = CGSize(
                width: encodedPixelSize.height * sourceAspect,
                height: encodedPixelSize.height
            )
        } else {
            fittedPixelSize = CGSize(
                width: encodedPixelSize.width,
                height: encodedPixelSize.width / max(0.001, sourceAspect)
            )
        }
        return MirageStreamGeometry.normalizedLogicalSize(
            CGSize(
                width: fittedPixelSize.width / displayScaleFactor,
                height: fittedPixelSize.height / displayScaleFactor
            )
        )
    }

    struct AutomaticDesktopWorkloadReconfigurationDecision: Equatable {
        let shouldChangeFrameRate: Bool
        let shouldResize: Bool
    }

    nonisolated static func automaticDesktopWorkloadReconfigurationDecision(
        needsFrameRateChange: Bool,
        needsResize: Bool,
        allowsAutomaticResolutionResize: Bool
    ) -> AutomaticDesktopWorkloadReconfigurationDecision {
        guard !needsResize || allowsAutomaticResolutionResize else {
            return AutomaticDesktopWorkloadReconfigurationDecision(
                shouldChangeFrameRate: false,
                shouldResize: false
            )
        }
        return AutomaticDesktopWorkloadReconfigurationDecision(
            shouldChangeFrameRate: needsFrameRateChange,
            shouldResize: needsResize && allowsAutomaticResolutionResize
        )
    }
}
