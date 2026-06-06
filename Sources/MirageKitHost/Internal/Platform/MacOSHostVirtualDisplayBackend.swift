//
//  MacOSHostVirtualDisplayBackend.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
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
#if os(macOS)
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Live macOS implementation of shared host virtual display management.
struct MacOSHostVirtualDisplayBackend: MirageHostVirtualDisplayBackend {
    private let manager: SharedVirtualDisplayManager
    private let windowSpaceManager: WindowSpaceManager

    init(
        manager: SharedVirtualDisplayManager = .shared,
        windowSpaceManager: WindowSpaceManager = .shared
    ) {
        self.manager = manager
        self.windowSpaceManager = windowSpaceManager
    }

    var displayID: CGDirectDisplayID? {
        get async {
            await manager.displayID
        }
    }

    var displaySnapshot: MirageHostVirtualDisplaySnapshot? {
        get async {
            await manager.displaySnapshot.map(MirageHostVirtualDisplaySnapshot.init(snapshot:))
        }
    }

    var displayBounds: CGRect? {
        get async {
            await manager.displayBounds
        }
    }

    var currentDisplayGeneration: UInt64 {
        get async {
            await manager.currentDisplayGeneration
        }
    }

    var statistics: (
        hasDisplay: Bool,
        consumerCount: Int,
        resolution: CGSize?,
        dedicatedDisplayCount: Int
    ) {
        get async {
            await manager.statistics
        }
    }

    func acquireDisplayForConsumer(
        _ consumer: MirageHostVirtualDisplayConsumer,
        resolution: CGSize?,
        refreshRate: Int,
        colorSpace: MirageMedia.MirageColorSpace,
        allowActiveUpdate: Bool,
        creationPolicy: MirageHostVirtualDisplayCreationPolicy,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostVirtualDisplaySnapshot {
        let snapshot = try await manager.acquireDisplayForConsumer(
            SharedVirtualDisplayManager.DisplayConsumer(consumer: consumer),
            resolution: resolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace,
            allowActiveUpdate: allowActiveUpdate,
            creationPolicy: SharedVirtualDisplayManager.DisplayCreationPolicy(policy: creationPolicy),
            startupBudget: startupBudget
        )
        return MirageHostVirtualDisplaySnapshot(snapshot: snapshot)
    }

    func releaseDisplayForConsumer(_ consumer: MirageHostVirtualDisplayConsumer) async {
        await manager.releaseDisplayForConsumer(SharedVirtualDisplayManager.DisplayConsumer(consumer: consumer))
    }

    func updateDisplayResolution(
        for consumer: MirageHostVirtualDisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int,
        resizeRequest: MirageHostVirtualDisplayResizeRequest?,
        allowRecreation: Bool
    ) async throws -> MirageHostDisplayResolutionUpdateResult {
        let result = try await manager.updateDisplayResolution(
            for: SharedVirtualDisplayManager.DisplayConsumer(consumer: consumer),
            newResolution: newResolution,
            refreshRate: refreshRate,
            resizeRequest: resizeRequest.map(DesktopVirtualDisplayResizeRequest.init(resizeRequest:)),
            allowRecreation: allowRecreation
        )
        return MirageHostDisplayResolutionUpdateResult(result: result)
    }

    func updateSharedDisplayObservedResolution(
        displayID: CGDirectDisplayID,
        resolution: CGSize
    ) async -> MirageHostVirtualDisplaySnapshot? {
        await manager.updateSharedDisplayObservedResolution(
            displayID: displayID,
            resolution: resolution
        ).map(MirageHostVirtualDisplaySnapshot.init(snapshot:))
    }

    func findCaptureDisplay(
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay {
        let displayWrapper = try await manager.findSCDisplay(
            maxAttempts: maxAttempts,
            startupBudget: startupBudget
        )
        return MirageHostCaptureDisplay(displayWrapper: displayWrapper)
    }

    func findCaptureDisplay(
        displayID: CGDirectDisplayID,
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay {
        let displayWrapper = try await manager.findSCDisplay(
            displayID: displayID,
            maxAttempts: maxAttempts,
            startupBudget: startupBudget
        )
        return MirageHostCaptureDisplay(displayWrapper: displayWrapper)
    }

    func findMainCaptureDisplay() async throws -> MirageHostCaptureDisplay {
        let displayWrapper = try await manager.findMainSCDisplay()
        return MirageHostCaptureDisplay(displayWrapper: displayWrapper)
    }

    func validateDisplayCadence(
        _ snapshot: MirageHostVirtualDisplaySnapshot,
        targetFrameRate: Int
    ) async -> MirageHostVirtualDisplayCadenceValidation {
        let validation = await manager.validateDisplayCadence(
            SharedVirtualDisplayManager.DisplaySnapshot(snapshot: snapshot),
            targetFrameRate: targetFrameRate
        )
        return MirageHostVirtualDisplayCadenceValidation(validation: validation)
    }

    func currentDisplayModeSizes(_ displayID: CGDirectDisplayID) -> MirageHostDisplayModeSizes? {
        CGVirtualDisplayBridge.currentDisplayModeSizes(displayID).map(MirageHostDisplayModeSizes.init(modeSizes:))
    }

    func displayBounds(_ displayID: CGDirectDisplayID) -> CGRect {
        CGVirtualDisplayBridge.displayBounds(displayID)
    }

    func displayBounds(
        _ displayID: CGDirectDisplayID,
        knownResolution: CGSize
    ) -> CGRect {
        CGVirtualDisplayBridge.displayBounds(displayID, knownResolution: knownResolution)
    }

    func displayVisibleBounds(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect {
        CGVirtualDisplayBridge.displayVisibleBounds(displayID, knownBounds: knownBounds)
    }

    func displayCaptureSourceRect(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect {
        CGVirtualDisplayBridge.displayCaptureSourceRect(displayID, knownBounds: knownBounds)
    }

    func displayColorSpaceValidation(
        observedColorSpace: CGColorSpace,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult {
        CGVirtualDisplayBridge.displayColorSpaceValidation(
            observedColorSpace: observedColorSpace,
            expectedColorSpace: expectedColorSpace
        ).mirageHostResult
    }

    func displayColorSpaceValidation(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult {
        CGVirtualDisplayBridge.displayColorSpaceValidation(
            displayID: displayID,
            expectedColorSpace: expectedColorSpace
        ).mirageHostResult
    }

    func isMirageDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGVirtualDisplayBridge.isMirageDisplay(displayID)
    }

    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGVirtualDisplayBridge.isVirtualDisplay(displayID)
    }

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return Array(displays.prefix(Int(displayCount)))
    }

    func mirroredDisplay(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID {
        CGDisplayMirrorsDisplay(displayID)
    }

    func displaysToMirror(excludingDisplayID displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        CGVirtualDisplayBridge.displaysToMirror(excludingDisplayID: displayID)
    }

    func space(for displayID: CGDirectDisplayID) -> CGSSpaceID {
        CGVirtualDisplayBridge.space(for: displayID)
    }

    func invalidateAllPersistentSerials() {
        CGVirtualDisplayBridge.invalidateAllPersistentSerials()
    }

    func withDisplayMutation<T: Sendable>(
        kind: VirtualDisplayMutationKind,
        operation: @MainActor () async -> T
    ) async -> T {
        let lease = await VirtualDisplayMutationCoordinator.shared.acquire(kind: kind)
        let result = await operation()
        await VirtualDisplayMutationCoordinator.shared.release(lease)
        return result
    }

    func applyDisplayMirroring(
        _ requests: [MirageHostDisplayMirroringRequest]
    ) async -> MirageHostDisplayMirroringResult {
        await withDisplayMutation(kind: .displayMirroring) {
            var configRef: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
                return MirageHostDisplayMirroringResult(
                    completed: false,
                    committedDisplayIDs: [],
                    failureDescription: "failed to begin display configuration"
                )
            }

            var acceptedDisplayIDs: [CGDirectDisplayID] = []
            var failedDisplayErrors: [CGDirectDisplayID: String] = [:]
            for request in requests {
                let result = CGConfigureDisplayMirrorOfDisplay(
                    config,
                    request.displayID,
                    request.mirroredDisplayID
                )
                if result == .success {
                    acceptedDisplayIDs.append(request.displayID)
                } else {
                    failedDisplayErrors[request.displayID] = "\(result)"
                }
            }

            guard !acceptedDisplayIDs.isEmpty else {
                CGCancelDisplayConfiguration(config)
                return MirageHostDisplayMirroringResult(
                    completed: false,
                    committedDisplayIDs: [],
                    failedDisplayErrors: failedDisplayErrors
                )
            }

            let completion = CGCompleteDisplayConfiguration(config, .forSession)
            guard completion == .success else {
                CGCancelDisplayConfiguration(config)
                return MirageHostDisplayMirroringResult(
                    completed: false,
                    committedDisplayIDs: [],
                    failedDisplayErrors: failedDisplayErrors,
                    failureDescription: "failed to complete configuration \(completion)"
                )
            }

            return MirageHostDisplayMirroringResult(
                completed: true,
                committedDisplayIDs: acceptedDisplayIDs,
                failedDisplayErrors: failedDisplayErrors
            )
        }
    }

    func windowSpaces(for windowID: WindowID) -> [CGSSpaceID] {
        CGSWindowSpaceBridge.spaces(for: windowID)
    }

    func moveWindowToSpace(_ windowID: WindowID, spaceID: CGSSpaceID) {
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
    }

    func prepareWindowForMirroredCapture(
        _ windowID: WindowID,
        owner: WindowSpaceManager.WindowBindingOwner?
    ) async throws {
        try await windowSpaceManager.prepareWindowForMirroredCapture(
            windowID,
            owner: owner
        )
    }

    func moveWindow(
        _ windowID: WindowID,
        toSpaceID spaceID: CGSSpaceID,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        targetContentAspectRatio: CGFloat?,
        owner: WindowSpaceManager.WindowBindingOwner?
    ) async throws {
        try await windowSpaceManager.moveWindow(
            windowID,
            toSpaceID: spaceID,
            displayID: displayID,
            displayBounds: displayBounds,
            targetContentAspectRatio: targetContentAspectRatio,
            owner: owner
        )
    }

    func restoreWindow(
        _ windowID: WindowID,
        expectedOwner: WindowSpaceManager.WindowBindingOwner?
    ) async throws {
        try await windowSpaceManager.restoreWindow(
            windowID,
            expectedOwner: expectedOwner
        )
    }

    func restoreWindowSilently(
        _ windowID: WindowID,
        expectedOwner: WindowSpaceManager.WindowBindingOwner?
    ) async {
        await windowSpaceManager.restoreWindowSilently(
            windowID,
            expectedOwner: expectedOwner
        )
    }

    func centerWindow(_ windowID: WindowID, on displayBounds: CGRect) async {
        await windowSpaceManager.centerWindow(windowID, on: displayBounds)
    }

    func resizeWindow(_ windowID: WindowID, to size: CGSize) async -> Bool {
        await windowSpaceManager.resizeWindow(windowID, to: size)
    }

    func resizeWindowWithAccessibilityResult(
        _ windowID: WindowID,
        to size: CGSize
    ) async -> WindowAccessibilityResizeResult {
        await windowSpaceManager.resizeWindowWithAccessibilityResult(windowID, to: size)
    }

    func claimedWindowIDsForActiveOwners(activeStreamIDs: Set<StreamID>) async -> Set<WindowID> {
        await windowSpaceManager.claimedWindowIDsForActiveOwners(activeStreamIDs: activeStreamIDs)
    }

    func restoreAllWindowsOwned(by streamID: StreamID) async {
        await windowSpaceManager.restoreAllWindowsOwned(by: streamID)
    }

    func setGenerationChangeHandler(
        _ handler: (@Sendable (MirageHostVirtualDisplaySnapshot, UInt64) -> Void)?
    ) async {
        let managerHandler: (@Sendable (SharedVirtualDisplayManager.DisplaySnapshot, UInt64) -> Void)? = if let handler {
            { snapshot, previousGeneration in
                handler(MirageHostVirtualDisplaySnapshot(snapshot: snapshot), previousGeneration)
            }
        } else {
            nil
        }
        await manager.setGenerationChangeHandler(managerHandler)
    }

    func destroyAllAndClear() async {
        await manager.destroyAllAndClear()
    }

    func resetVirtualDisplayIdentity() async throws {
        try await manager.resetVirtualDisplayIdentity()
    }
}

private extension SharedVirtualDisplayManager.DisplayConsumer {
    init(consumer: MirageHostVirtualDisplayConsumer) {
        switch consumer {
        case .desktopStream:
            self = .desktopStream
        case .appStream:
            self = .appStream
        }
    }
}

private extension SharedVirtualDisplayManager.DisplayCreationPolicy {
    init(policy: MirageHostVirtualDisplayCreationPolicy) {
        switch policy {
        case .adaptiveRetinaThenFallback1xAndColor:
            self = .adaptiveRetinaThenFallback1xAndColor
        case let .singleAttempt(hiDPI):
            self = .singleAttempt(hiDPI: hiDPI)
        }
    }
}

private extension MirageHostCaptureDisplay {
    init(displayWrapper: SCDisplayWrapper) {
        self.init(displayID: displayWrapper.display.displayID, pixelSize: CGSize(width: CGFloat(displayWrapper.display.width), height: CGFloat(displayWrapper.display.height)))
    }
}

private extension MirageHostDisplayModeSizes {
    init(modeSizes: CGVirtualDisplayBridge.DisplayModeSizes) {
        self.init(logical: modeSizes.logical, pixel: modeSizes.pixel)
    }
}

private extension SharedVirtualDisplayManager.DisplaySnapshot {
    init(snapshot: MirageHostVirtualDisplaySnapshot) {
        self.init(
            displayID: snapshot.displayID,
            spaceID: snapshot.spaceID,
            resolution: snapshot.resolution,
            scaleFactor: snapshot.scaleFactor,
            refreshRate: snapshot.refreshRate,
            colorSpace: snapshot.colorSpace,
            displayP3CoverageStatus: snapshot.displayP3CoverageStatus,
            generation: snapshot.generation,
            createdAt: snapshot.createdAt
        )
    }
}

private extension MirageHostDisplayResolutionUpdateOutcome {
    init(outcome: SharedVirtualDisplayManager.DisplayResolutionUpdateOutcome) {
        switch outcome {
        case .noChange:
            self = .noChange
        case .updatedInPlace:
            self = .updatedInPlace
        case .requiresRecreation:
            self = .requiresRecreation
        case .recreated:
            self = .recreated
        }
    }
}

private extension MirageHostDisplayResolutionUpdateResult {
    init(result: SharedVirtualDisplayManager.DisplayResolutionUpdateResult) {
        self.init(
            outcome: MirageHostDisplayResolutionUpdateOutcome(outcome: result.outcome),
            generationChanged: result.generationChanged
        )
    }
}

private extension MirageHostVirtualDisplayCadenceValidation {
    init(validation: SharedVirtualDisplayManager.VirtualDisplayCadenceValidation) {
        self.init(
            targetFPS: validation.targetFPS,
            observedFPS: validation.observedFPS,
            usesNativeDisplayCadence: validation.usesNativeDisplayCadence
        )
    }
}

private extension CGVirtualDisplayBridge.DisplayColorSpaceValidationResult {
    var mirageHostResult: MirageHostDisplayColorSpaceValidationResult {
        MirageHostDisplayColorSpaceValidationResult(
            coverageStatus: coverageStatus,
            observedName: observedName
        )
    }
}
#endif
