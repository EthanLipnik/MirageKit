//
//  MirageHostService+DisplayTopology.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
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
import AppKit

@MainActor
extension MirageHostService {
    /// Debounce window for coalescing rapid display-topology notifications before restarting capture.
    private static let desktopDisplayTopologyRefreshDebounce: Duration = .milliseconds(350)

    /// Registers for host display topology notifications while desktop streaming can react to them.
    func ensureScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleScreenParametersChange()
            }
        }
    }

    /// Removes the display topology notification observer.
    func removeScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
    }

    /// Handles display topology changes by refreshing input geometry or restarting capture.
    func handleScreenParametersChange() async {
        guard let desktopStreamID else { return }

        let previousDisplayBounds = desktopDisplayBounds
        let previousPrimaryPhysicalBounds = desktopPrimaryPhysicalBounds
        let previousPhysicalTopologySignature = desktopPhysicalDisplayTopologySignature
        let previousVirtualResolution = desktopMirroredVirtualResolution
        let refreshedDisplayBounds = resolveDesktopDisplayBounds()
        let refreshedPhysicalBounds = refreshDesktopPrimaryPhysicalBounds()
        let refreshedPhysicalTopologySignature = currentPhysicalDisplayTopologySignature()
        desktopPhysicalDisplayTopologySignature = refreshedPhysicalTopologySignature
        let virtualResolution = await currentDesktopVirtualDisplayPixelResolution(
            fallback: previousVirtualResolution
        )
        let geometry = updateDesktopInputGeometry(
            streamID: desktopStreamID,
            physicalBounds: refreshedPhysicalBounds,
            virtualResolution: virtualResolution
        )

        let displayBoundsChanged = refreshedDisplayBounds != previousDisplayBounds
        let physicalBoundsChanged = refreshedPhysicalBounds != previousPrimaryPhysicalBounds
        let virtualResolutionChanged = desktopVirtualResolutionChanged(
            from: previousVirtualResolution,
            to: geometry.virtualResolution
        )
        let physicalTopologyChanged =
            previousPhysicalTopologySignature != nil &&
            refreshedPhysicalTopologySignature != previousPhysicalTopologySignature
        guard displayBoundsChanged || physicalBoundsChanged || physicalTopologyChanged || virtualResolutionChanged else {
            return
        }
        let displaySizeChanged = refreshedDisplayBounds?.size != previousDisplayBounds?.size
        let physicalSizeChanged = refreshedPhysicalBounds.size != previousPrimaryPhysicalBounds?.size

        MirageLogger.host(
            "Desktop display topology changed; refreshed input bounds to \(geometry.inputBounds) " +
                "(physicalTopologyChanged=\(physicalTopologyChanged))"
        )

        let requiresVirtualDisplayRestart =
            !desktopUsesHostResolution &&
            (displaySizeChanged || physicalSizeChanged || physicalTopologyChanged || virtualResolutionChanged)

        if requiresVirtualDisplayRestart {
            scheduleDesktopDisplayTopologyRefresh(
                streamID: desktopStreamID,
                virtualResolution: geometry.virtualResolution,
                reason: "screen_parameters_changed"
            )
            return
        }

        if virtualResolutionChanged,
           let virtualResolution = geometry.virtualResolution,
           await resetDesktopCaptureForUnmanagedResolutionChangeIfNeeded(
               streamID: desktopStreamID,
               virtualResolution: virtualResolution
           ) {
            return
        }

        if displaySizeChanged || physicalSizeChanged || virtualResolutionChanged {
            await sendStreamScaleUpdate(streamID: desktopStreamID)
        }
    }

    /// Returns a stable signature for the active physical display layout.
    func currentPhysicalDisplayTopologySignature() -> String? {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success, displayCount > 0 else { return nil }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        guard listResult == .success else { return nil }

        let entries = displayIDs
            .prefix(Int(displayCount))
            .filter { !platformVirtualDisplayBackend.isMirageDisplay($0) }
            .sorted()
            .map { displayID in
                let bounds = CGDisplayBounds(displayID)
                let mode = CGDisplayCopyDisplayMode(displayID)
                let pixelWidth = mode?.pixelWidth ?? 0
                let pixelHeight = mode?.pixelHeight ?? 0
                let refreshRate = mode.map { Int($0.refreshRate.rounded()) } ?? 0
                let isMain = displayID == CGMainDisplayID() ? 1 : 0
                return [
                    String(displayID),
                    String(isMain),
                    String(Int(bounds.origin.x.rounded())),
                    String(Int(bounds.origin.y.rounded())),
                    String(Int(bounds.width.rounded())),
                    String(Int(bounds.height.rounded())),
                    String(pixelWidth),
                    String(pixelHeight),
                    String(refreshRate),
                ].joined(separator: ":")
            }

        return entries.isEmpty ? nil : entries.joined(separator: "|")
    }

    /// Debounces a desktop virtual-display restart after host display topology changes.
    func scheduleDesktopDisplayTopologyRefresh(
        streamID: StreamID,
        virtualResolution: CGSize?,
        reason: String
    ) {
        desktopDisplayTopologyRefreshTask?.cancel()
        desktopDisplayTopologyRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.desktopDisplayTopologyRefreshDebounce)
            } catch {
                return
            }

            guard let self else { return }
            await restartDesktopVirtualDisplayAfterTopologyChange(
                streamID: streamID,
                virtualResolution: virtualResolution,
                reason: reason
            )
        }
    }

    /// Resolves the current desktop virtual-display pixel resolution from live and cached state.
    func currentDesktopVirtualDisplayPixelResolution(fallback: CGSize? = nil) async -> CGSize? {
        let liveResolution = desktopVirtualDisplayID.flatMap {
            platformVirtualDisplayBackend.currentDisplayModeSizes($0)?.pixel
        }
        let sharedSnapshot = await platformVirtualDisplayBackend.displaySnapshot
        let sharedResolution: CGSize? = if desktopUsesHostResolution {
            nil
        } else if let desktopVirtualDisplayID, sharedSnapshot?.displayID == desktopVirtualDisplayID {
            sharedSnapshot?.resolution
        } else if desktopVirtualDisplayID == nil {
            sharedSnapshot?.resolution
        } else {
            nil
        }
        let streamResolution: CGSize? = if desktopUsesHostResolution {
            nil
        } else {
            await desktopStreamContext?.virtualDisplayContext?.resolution
        }

        return resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: liveResolution,
            sharedSnapshotResolution: sharedResolution,
            streamSnapshotResolution: streamResolution,
            cachedResolution: desktopMirroredVirtualResolution,
            fallbackResolution: fallback
        )
    }

    /// Updates cached desktop input geometry and the input stream frame.
    func updateDesktopInputGeometry(
        streamID: StreamID,
        physicalBounds: CGRect? = nil,
        virtualResolution: CGSize?
    )
    -> DesktopInputGeometryRefreshResult {
        let resolvedPhysicalBounds = physicalBounds ?? refreshDesktopPrimaryPhysicalBounds()
        let resolvedVirtualResolution = validDesktopVirtualResolution(virtualResolution)
        desktopMirroredVirtualResolution = resolvedVirtualResolution
        let inputBounds = resolvedDesktopInputBounds(
            physicalBounds: resolvedPhysicalBounds,
            virtualResolution: resolvedVirtualResolution
        )
        inputStreamCache.updateWindowFrame(streamID, newFrame: inputBounds)
        return DesktopInputGeometryRefreshResult(
            virtualResolution: resolvedVirtualResolution,
            inputBounds: inputBounds
        )
    }

    /// Refreshes desktop input geometry without returning the resolved values.
    func refreshDesktopInputGeometry(
        streamID: StreamID,
        physicalBounds: CGRect? = nil,
        virtualResolution: CGSize?
    ) {
        _ = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )
    }

}

#endif
