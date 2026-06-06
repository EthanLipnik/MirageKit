//
//  MirageHostVirtualDisplayBackendTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import Foundation
import MirageKit
@testable import MirageKitHost
import Testing
import MirageCore
import MirageMedia

@Suite("Mirage Host Virtual Display Backend")
struct MirageHostVirtualDisplayBackendTests {
    @MainActor
    @Test("Host service resets virtual display identity through platform backend")
    func hostServiceResetsVirtualDisplayIdentityThroughPlatformBackend() async throws {
        let backend = RecordingVirtualDisplayBackend()
        let service = MirageHostService(
            hostName: "Virtual Display Backend Host",
            deviceID: UUID()
        )
        service.platformVirtualDisplayBackend = backend

        try await service.resetVirtualDisplayIdentity()

        #expect(await backend.resetCallCount() == 1)
    }

    @MainActor
    @Test("Host service display mutation routes through platform backend")
    func hostServiceDisplayMutationRoutesThroughPlatformBackend() async throws {
        let backend = RecordingVirtualDisplayBackend()
        let service = MirageHostService(
            hostName: "Virtual Display Mutation Host",
            deviceID: UUID()
        )
        service.platformVirtualDisplayBackend = backend

        let result = await service.withHostDisplayMutation(kind: .displayMirroring) {
            42
        }

        #expect(result == 42)
        #expect(await backend.mutationKinds() == [.displayMirroring])
    }

    @MainActor
    @Test("Host service captures mirroring snapshot through platform backend")
    func hostServiceCapturesMirroringSnapshotThroughPlatformBackend() async throws {
        let backend = RecordingVirtualDisplayBackend()
        backend.mirroredDisplays = [
            10: 20,
            11: kCGNullDirectDisplay
        ]
        let service = MirageHostService(
            hostName: "Virtual Display Snapshot Host",
            deviceID: UUID()
        )
        service.platformVirtualDisplayBackend = backend

        let snapshot = service.captureDisplayMirroringSnapshot(for: [10, 11, 12])

        #expect(snapshot == [
            10: 20,
            11: kCGNullDirectDisplay,
            12: kCGNullDirectDisplay
        ])
    }

    @MainActor
    @Test("Host service placement drift reads window spaces through platform backend")
    func hostServicePlacementDriftReadsWindowSpacesThroughPlatformBackend() async throws {
        let backend = RecordingVirtualDisplayBackend()
        backend.windowSpacesByWindowID = [700: [44]]
        let service = MirageHostService(
            hostName: "Virtual Display Placement Host",
            deviceID: UUID()
        )
        service.platformVirtualDisplayBackend = backend

        let reason = service.virtualDisplayPlacementDriftReason(
            windowID: 700,
            expectedSpaceID: 55,
            state: MirageHostService.WindowVirtualDisplayState(
                streamID: 71,
                displayID: 88,
                generation: 1,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                displayVisibleBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                targetContentAspectRatio: nil,
                captureSourceRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                visiblePixelResolution: CGSize(width: 800, height: 600),
                displayVisiblePixelResolution: CGSize(width: 800, height: 600),
                scaleFactor: 1,
                pixelResolution: CGSize(width: 800, height: 600),
                clientScaleFactor: 1
            )
        )

        #expect(reason == "space drift expected=55 actual=[44]")
    }

    @Test("Virtual display backend exposes Mirage-owned value contracts")
    func virtualDisplayBackendExposesMirageOwnedValueContracts() async throws {
        let snapshot = Self.displaySnapshot()
        let backend = RecordingVirtualDisplayBackend()
        backend.snapshot = snapshot
        backend.modeSizes = MirageHostDisplayModeSizes(
            logical: CGSize(width: 1024, height: 768),
            pixel: CGSize(width: 2048, height: 1536)
        )
        backend.captureDisplay = MirageHostCaptureDisplay(displayID: 123, pixelSize: CGSize(width: 2048, height: 1536))

        #expect(await backend.displaySnapshot == snapshot)
        #expect(backend.currentDisplayModeSizes(123)?.pixel == CGSize(width: 2048, height: 1536))

        let acquiredSnapshot = try await backend.acquireDisplayForConsumer(
            .appStream,
            resolution: snapshot.resolution,
            refreshRate: 60,
            colorSpace: .displayP3,
            allowActiveUpdate: true,
            creationPolicy: .singleAttempt(hiDPI: true),
            startupBudget: nil
        )
        #expect(acquiredSnapshot == snapshot)
        await backend.releaseDisplayForConsumer(.appStream)
        #expect(await backend.acquireRequests() == [
            MirageHostVirtualDisplayAcquireRequest(
                consumer: .appStream,
                creationPolicy: .singleAttempt(hiDPI: true)
            )
        ])
        #expect(await backend.releaseRequests() == [.appStream])

        let resizeRequest = MirageHostVirtualDisplayResizeRequest(
            requestedPixelWidth: 2048,
            requestedPixelHeight: 1536,
            requestedRefreshRate: 60,
            requestedColorSpace: .displayP3,
            requestedHiDPI: true
        )
        let updateResult = try await backend.updateDisplayResolution(
            for: .desktopStream,
            newResolution: snapshot.resolution,
            refreshRate: 60,
            resizeRequest: resizeRequest,
            allowRecreation: false
        )
        #expect(updateResult.outcome == .noChange)
        #expect(!updateResult.generationChanged)
        #expect(await backend.updateRequests() == [
            MirageHostVirtualDisplayUpdateRequest(
                consumer: .desktopStream,
                newResolution: snapshot.resolution,
                refreshRate: 60,
                resizeRequest: resizeRequest,
                allowRecreation: false
            )
        ])

        let captureDisplay = try await backend.findCaptureDisplay(maxAttempts: 1, startupBudget: nil)
        #expect(captureDisplay.displayID == 123)
        #expect(captureDisplay.pixelSize == CGSize(width: 2048, height: 1536))

        let cadenceValidation = await backend.validateDisplayCadence(snapshot, targetFrameRate: 60)
        #expect(cadenceValidation.targetFPS == 60)
        #expect(!cadenceValidation.usesNativeDisplayCadence)
        #expect(cadenceValidation.logLabel.contains("target=60Hz"))

        let colorValidation = backend.displayColorSpaceValidation(
            observedColorSpace: CGColorSpaceCreateDeviceRGB(),
            expectedColorSpace: .displayP3
        )
        #expect(colorValidation.coverageStatus == .unresolved)
        #expect(!colorValidation.isAcceptableForDisplayP3)
    }

    private static func displaySnapshot() -> MirageHostVirtualDisplaySnapshot {
        MirageHostVirtualDisplaySnapshot(
            displayID: 123,
            spaceID: 456,
            resolution: CGSize(width: 2048, height: 1536),
            scaleFactor: 2,
            refreshRate: 60,
            colorSpace: .displayP3,
            displayP3CoverageStatus: .strictCanonical,
            generation: 7,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private actor RecordingVirtualDisplayBackend: MirageHostVirtualDisplayBackend {
    private var resetCalls = 0
    private var recordedMutationKinds: [VirtualDisplayMutationKind] = []
    private var recordedAcquireRequests: [MirageHostVirtualDisplayAcquireRequest] = []
    private var recordedReleaseRequests: [MirageHostVirtualDisplayConsumer] = []
    private var recordedUpdateRequests: [MirageHostVirtualDisplayUpdateRequest] = []
    nonisolated(unsafe) var mirroredDisplays: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    nonisolated(unsafe) var onlineDisplays: [CGDirectDisplayID] = []
    nonisolated(unsafe) var windowSpacesByWindowID: [WindowID: [CGSSpaceID]] = [:]
    nonisolated(unsafe) var claimedWindowIDs: Set<WindowID> = []
    nonisolated(unsafe) var snapshot: MirageHostVirtualDisplaySnapshot?
    nonisolated(unsafe) var captureDisplay: MirageHostCaptureDisplay?
    nonisolated(unsafe) var modeSizes: MirageHostDisplayModeSizes?

    var displayID: CGDirectDisplayID? { nil }

    var displaySnapshot: MirageHostVirtualDisplaySnapshot? { snapshot }

    var displayBounds: CGRect? { nil }

    var currentDisplayGeneration: UInt64 { 0 }

    var statistics: (
        hasDisplay: Bool,
        consumerCount: Int,
        resolution: CGSize?,
        dedicatedDisplayCount: Int
    ) {
        (
            hasDisplay: false,
            consumerCount: 0,
            resolution: nil,
            dedicatedDisplayCount: 0
        )
    }

    func acquireDisplayForConsumer(
        _ consumer: MirageHostVirtualDisplayConsumer,
        resolution _: CGSize?,
        refreshRate _: Int,
        colorSpace _: MirageMedia.MirageColorSpace,
        allowActiveUpdate _: Bool,
        creationPolicy: MirageHostVirtualDisplayCreationPolicy,
        startupBudget _: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostVirtualDisplaySnapshot {
        recordedAcquireRequests.append(
            MirageHostVirtualDisplayAcquireRequest(
                consumer: consumer,
                creationPolicy: creationPolicy
            )
        )
        guard let snapshot else {
            throw MirageCore.MirageError.protocolError("Recording backend has no snapshot to allocate")
        }
        return snapshot
    }

    func releaseDisplayForConsumer(_ consumer: MirageHostVirtualDisplayConsumer) async {
        recordedReleaseRequests.append(consumer)
    }

    func updateDisplayResolution(
        for consumer: MirageHostVirtualDisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int,
        resizeRequest: MirageHostVirtualDisplayResizeRequest?,
        allowRecreation: Bool
    ) async throws -> MirageHostDisplayResolutionUpdateResult {
        recordedUpdateRequests.append(
            MirageHostVirtualDisplayUpdateRequest(
                consumer: consumer,
                newResolution: newResolution,
                refreshRate: refreshRate,
                resizeRequest: resizeRequest,
                allowRecreation: allowRecreation
            )
        )
        return MirageHostDisplayResolutionUpdateResult(
            outcome: .noChange,
            generationChanged: false
        )
    }

    func updateSharedDisplayObservedResolution(
        displayID _: CGDirectDisplayID,
        resolution _: CGSize
    ) async -> MirageHostVirtualDisplaySnapshot? {
        nil
    }

    func findCaptureDisplay(
        maxAttempts _: Int,
        startupBudget _: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay {
        guard let captureDisplay else {
            throw MirageCore.MirageError.protocolError("Recording backend does not resolve displays")
        }
        return captureDisplay
    }

    func findCaptureDisplay(
        displayID _: CGDirectDisplayID,
        maxAttempts _: Int,
        startupBudget _: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay {
        guard let captureDisplay else {
            throw MirageCore.MirageError.protocolError("Recording backend does not resolve displays")
        }
        return captureDisplay
    }

    func findMainCaptureDisplay() async throws -> MirageHostCaptureDisplay {
        guard let captureDisplay else {
            throw MirageCore.MirageError.protocolError("Recording backend does not resolve displays")
        }
        return captureDisplay
    }

    func validateDisplayCadence(
        _: MirageHostVirtualDisplaySnapshot,
        targetFrameRate: Int
    ) async -> MirageHostVirtualDisplayCadenceValidation {
        MirageHostVirtualDisplayCadenceValidation(
            targetFPS: Double(targetFrameRate),
            observedFPS: nil,
            usesNativeDisplayCadence: false
        )
    }

    nonisolated func currentDisplayModeSizes(_: CGDirectDisplayID) -> MirageHostDisplayModeSizes? { modeSizes }

    nonisolated func displayBounds(_: CGDirectDisplayID) -> CGRect { .zero }

    nonisolated func displayBounds(
        _: CGDirectDisplayID,
        knownResolution: CGSize
    ) -> CGRect {
        CGRect(origin: .zero, size: knownResolution)
    }

    nonisolated func displayVisibleBounds(
        _: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect {
        knownBounds ?? .zero
    }

    nonisolated func displayCaptureSourceRect(
        _: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect {
        knownBounds ?? .zero
    }

    nonisolated func displayColorSpaceValidation(
        observedColorSpace _: CGColorSpace,
        expectedColorSpace _: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult {
        MirageHostDisplayColorSpaceValidationResult(
            coverageStatus: .unresolved,
            observedName: nil
        )
    }

    nonisolated func displayColorSpaceValidation(
        displayID _: CGDirectDisplayID,
        expectedColorSpace _: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult {
        MirageHostDisplayColorSpaceValidationResult(
            coverageStatus: .unresolved,
            observedName: nil
        )
    }

    nonisolated func isMirageDisplay(_: CGDirectDisplayID) -> Bool { false }

    nonisolated func isVirtualDisplay(_: CGDirectDisplayID) -> Bool { false }

    nonisolated func onlineDisplayIDs() -> [CGDirectDisplayID] { onlineDisplays }

    nonisolated func mirroredDisplay(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID {
        mirroredDisplays[displayID] ?? kCGNullDirectDisplay
    }

    nonisolated func displaysToMirror(excludingDisplayID _: CGDirectDisplayID) -> [CGDirectDisplayID] { [] }

    nonisolated func space(for _: CGDirectDisplayID) -> CGSSpaceID { 0 }

    nonisolated func invalidateAllPersistentSerials() {}

    func withDisplayMutation<T: Sendable>(
        kind: VirtualDisplayMutationKind,
        operation: @MainActor () async -> T
    ) async -> T {
        recordedMutationKinds.append(kind)
        return await operation()
    }

    func applyDisplayMirroring(
        _ requests: [MirageHostDisplayMirroringRequest]
    ) async -> MirageHostDisplayMirroringResult {
        MirageHostDisplayMirroringResult(
            completed: true,
            committedDisplayIDs: requests.map(\.displayID)
        )
    }

    nonisolated func windowSpaces(for windowID: WindowID) -> [CGSSpaceID] {
        windowSpacesByWindowID[windowID] ?? []
    }

    nonisolated func moveWindowToSpace(_: WindowID, spaceID _: CGSSpaceID) {}

    func prepareWindowForMirroredCapture(
        _: WindowID,
        owner _: WindowSpaceManager.WindowBindingOwner?
    ) async throws {}

    func moveWindow(
        _: WindowID,
        toSpaceID _: CGSSpaceID,
        displayID _: CGDirectDisplayID,
        displayBounds _: CGRect,
        targetContentAspectRatio _: CGFloat?,
        owner _: WindowSpaceManager.WindowBindingOwner?
    ) async throws {}

    func restoreWindow(
        _: WindowID,
        expectedOwner _: WindowSpaceManager.WindowBindingOwner?
    ) async throws {}

    func restoreWindowSilently(
        _: WindowID,
        expectedOwner _: WindowSpaceManager.WindowBindingOwner?
    ) async {}

    func centerWindow(_: WindowID, on _: CGRect) async {}

    func resizeWindow(_: WindowID, to _: CGSize) async -> Bool { true }

    func resizeWindowWithAccessibilityResult(
        _: WindowID,
        to size: CGSize
    ) async -> WindowAccessibilityResizeResult {
        WindowAccessibilityResizeResult(
            outcome: .applied,
            observedFrame: CGRect(origin: .zero, size: size),
            reason: "applied"
        )
    }

    func claimedWindowIDsForActiveOwners(activeStreamIDs _: Set<StreamID>) async -> Set<WindowID> { claimedWindowIDs }

    func restoreAllWindowsOwned(by _: StreamID) async {}

    func setGenerationChangeHandler(
        _: (@Sendable (MirageHostVirtualDisplaySnapshot, UInt64) -> Void)?
    ) async {}

    func destroyAllAndClear() async {}

    func resetVirtualDisplayIdentity() async throws { resetCalls += 1 }

    func resetCallCount() -> Int { resetCalls }

    func mutationKinds() -> [VirtualDisplayMutationKind] { recordedMutationKinds }

    func acquireRequests() -> [MirageHostVirtualDisplayAcquireRequest] { recordedAcquireRequests }

    func releaseRequests() -> [MirageHostVirtualDisplayConsumer] { recordedReleaseRequests }

    func updateRequests() -> [MirageHostVirtualDisplayUpdateRequest] { recordedUpdateRequests }
}

private struct MirageHostVirtualDisplayAcquireRequest: Equatable, Sendable {
    let consumer: MirageHostVirtualDisplayConsumer
    let creationPolicy: MirageHostVirtualDisplayCreationPolicy
}

private struct MirageHostVirtualDisplayUpdateRequest: Equatable, Sendable {
    let consumer: MirageHostVirtualDisplayConsumer
    let newResolution: CGSize
    let refreshRate: Int
    let resizeRequest: MirageHostVirtualDisplayResizeRequest?
    let allowRecreation: Bool
}
#endif
