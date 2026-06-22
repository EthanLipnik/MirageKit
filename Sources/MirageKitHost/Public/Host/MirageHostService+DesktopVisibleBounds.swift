//
//  MirageHostService+DesktopVisibleBounds.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/22/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

struct DesktopVisibleBoundsSnapshot: Sendable, Equatable {
    let bounds: CGRect
    let referenceSize: CGSize
}

@MainActor
extension MirageHostService {
    private static let desktopVisibleBoundsUpdateInterval: Duration = .seconds(3)
    private static let desktopVisibleBoundsTolerance: CGFloat = 0.5

    func startDesktopVisibleBoundsUpdates(
        streamID: StreamID,
        desktopSessionID: UUID,
        clientContext: ClientContext
    ) {
        desktopVisibleBoundsUpdateTask?.cancel()
        desktopVisibleBoundsUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await sendDesktopVisibleBoundsUpdateIfNeeded(
                    streamID: streamID,
                    desktopSessionID: desktopSessionID,
                    clientContext: clientContext
                )

                do {
                    try await Task.sleep(for: Self.desktopVisibleBoundsUpdateInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopDesktopVisibleBoundsUpdates() {
        desktopVisibleBoundsUpdateTask?.cancel()
        desktopVisibleBoundsUpdateTask = nil
        lastSentDesktopVisibleBounds = nil
    }

    @discardableResult
    func attachCurrentDesktopVisibleBounds(
        to message: inout DesktopStreamStartedMessage
    )
    async -> DesktopVisibleBoundsSnapshot? {
        guard let snapshot = await currentDesktopVisibleBoundsSnapshot() else {
            message.setDesktopVisibleBounds(nil, referenceSize: nil)
            return nil
        }
        message.setDesktopVisibleBounds(snapshot.bounds, referenceSize: snapshot.referenceSize)
        return snapshot
    }

    func recordSentDesktopVisibleBounds(_ snapshot: DesktopVisibleBoundsSnapshot?) {
        lastSentDesktopVisibleBounds = snapshot
    }

    private func sendDesktopVisibleBoundsUpdateIfNeeded(
        streamID: StreamID,
        desktopSessionID: UUID,
        clientContext: ClientContext
    )
    async {
        guard desktopStreamID == streamID,
              self.desktopSessionID == desktopSessionID,
              desktopStreamClientContext?.client.id == clientContext.client.id,
              let context = desktopStreamContext,
              let snapshot = await currentDesktopVisibleBoundsSnapshot(),
              !desktopVisibleBoundsSnapshotsMatch(snapshot, lastSentDesktopVisibleBounds) else {
            return
        }

        let streamStart = await context.streamStartSnapshot
        let encodedResolution = CGSize(
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height
        )
        let displayResolution = await currentDesktopStartedResolution(fallback: encodedResolution)
        let geometryContract = reusableCurrentDesktopGeometryContract(
            displayPixelResolution: displayResolution,
            encodedPixelResolution: encodedResolution,
            refreshTargetHz: streamStart.targetFrameRate
        )
        var message = DesktopStreamStartedMessage(
            streamID: streamID,
            desktopSessionID: desktopSessionID,
            width: Int(displayResolution.width),
            height: Int(displayResolution.height),
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            displayCount: 1,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
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
            desktopGeometryRefreshTargetHz: geometryContract.refreshTargetHz ?? streamStart.targetFrameRate
        )
        message.setDesktopVisibleBounds(snapshot.bounds, referenceSize: snapshot.referenceSize)

        guard clientContext.sendBestEffort(.desktopStreamStarted, content: message) else {
            MirageLogger.error(.host, "Failed to encode desktop visible-bounds update for stream \(streamID)")
            return
        }

        lastSentDesktopVisibleBounds = snapshot
    }

    private func currentDesktopVisibleBoundsSnapshot() async -> DesktopVisibleBoundsSnapshot? {
        guard desktopStreamID != nil else { return nil }

        let sharedSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
        let displayID: CGDirectDisplayID? = if let desktopVirtualDisplayID {
            desktopVirtualDisplayID
        } else if desktopCaptureSource == .virtualDisplay, let sharedSnapshot {
            sharedSnapshot.displayID
        } else {
            desktopPrimaryPhysicalDisplayID ?? resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
        }
        guard let displayID else { return nil }

        let displayBounds = resolvedDesktopVisibleBoundsDisplayBounds(
            displayID: displayID,
            sharedSnapshot: sharedSnapshot
        )
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }

        var visibleBounds = CGVirtualDisplayBridge.displayVisibleBounds(
            displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            visibleBounds = displayBounds
        }

        let localBounds = CGRect(
            x: visibleBounds.minX - displayBounds.minX,
            y: visibleBounds.minY - displayBounds.minY,
            width: visibleBounds.width,
            height: visibleBounds.height
        ).standardized
        guard localBounds.width > 0, localBounds.height > 0 else { return nil }

        return DesktopVisibleBoundsSnapshot(
            bounds: localBounds,
            referenceSize: displayBounds.size
        )
    }

    private func resolvedDesktopVisibleBoundsDisplayBounds(
        displayID: CGDirectDisplayID,
        sharedSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?
    )
    -> CGRect {
        if displayID == desktopVirtualDisplayID,
           let resolvedBounds = resolveDesktopDisplayBounds(),
           resolvedBounds.width > 0,
           resolvedBounds.height > 0 {
            return resolvedBounds
        }

        if let sharedSnapshot,
           sharedSnapshot.displayID == displayID {
            let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
                for: sharedSnapshot.resolution,
                scaleFactor: max(1.0, sharedSnapshot.scaleFactor)
            )
            return CGVirtualDisplayBridge.displayBounds(
                displayID,
                knownResolution: logicalResolution
            )
        }

        if let desktopDisplayBounds,
           desktopDisplayBounds.width > 0,
           desktopDisplayBounds.height > 0 {
            return desktopDisplayBounds
        }

        return CGDisplayBounds(displayID)
    }

    private func desktopVisibleBoundsSnapshotsMatch(
        _ lhs: DesktopVisibleBoundsSnapshot,
        _ rhs: DesktopVisibleBoundsSnapshot?
    )
    -> Bool {
        guard let rhs else { return false }
        return abs(lhs.bounds.minX - rhs.bounds.minX) <= Self.desktopVisibleBoundsTolerance &&
            abs(lhs.bounds.minY - rhs.bounds.minY) <= Self.desktopVisibleBoundsTolerance &&
            abs(lhs.bounds.width - rhs.bounds.width) <= Self.desktopVisibleBoundsTolerance &&
            abs(lhs.bounds.height - rhs.bounds.height) <= Self.desktopVisibleBoundsTolerance &&
            abs(lhs.referenceSize.width - rhs.referenceSize.width) <= Self.desktopVisibleBoundsTolerance &&
            abs(lhs.referenceSize.height - rhs.referenceSize.height) <= Self.desktopVisibleBoundsTolerance
    }
}

#endif
