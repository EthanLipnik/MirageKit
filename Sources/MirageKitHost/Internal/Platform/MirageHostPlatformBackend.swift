//
//  MirageHostPlatformBackend.swift
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

/// Stable Mirage-owned display identity used by host platform backend contracts.
struct MirageHostDisplayID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(_ rawValue: UInt32) {
        self.init(rawValue: rawValue)
    }
}

/// Product-level capture source request, independent of the macOS capture framework.
enum MirageHostCaptureSource: Hashable, Sendable {
    case display(MirageHostDisplayID)
    case window(WindowID)
    case displayWindowSet(
        displayID: MirageHostDisplayID,
        includedWindowIDs: [WindowID],
        excludedWindowIDs: [WindowID]
    )

    var windowIDs: Set<WindowID> {
        switch self {
        case .display:
            []
        case let .window(windowID):
            [windowID]
        case let .displayWindowSet(_, includedWindowIDs, excludedWindowIDs):
            Set(includedWindowIDs).union(excludedWindowIDs)
        }
    }
}

/// Host capture configuration expressed without ScreenCaptureKit types.
struct MirageHostCaptureConfiguration: Equatable, Sendable {
    let logicalSize: CGSize
    let captureResolution: CGSize?
    let sourceRect: CGRect?
    let destinationRect: CGRect?
    let contentWindowID: WindowID?
    let showsCursor: Bool
    let targetFrameRate: Int
    let queueDepth: Int
    let capturesAudio: Bool
    let audioConfiguration: MirageMedia.MirageAudioConfiguration
    let audioChannelCount: Int?

    init(
        logicalSize: CGSize,
        captureResolution: CGSize? = nil,
        sourceRect: CGRect? = nil,
        destinationRect: CGRect? = nil,
        contentWindowID: WindowID? = nil,
        showsCursor: Bool = false,
        targetFrameRate: Int,
        queueDepth: Int,
        capturesAudio: Bool = false,
        audioConfiguration: MirageMedia.MirageAudioConfiguration = .default,
        audioChannelCount: Int? = nil
    ) {
        self.logicalSize = logicalSize
        self.captureResolution = captureResolution
        self.sourceRect = sourceRect
        self.destinationRect = destinationRect
        self.contentWindowID = contentWindowID
        self.showsCursor = showsCursor
        self.targetFrameRate = max(1, targetFrameRate)
        self.queueDepth = max(1, queueDepth)
        self.capturesAudio = capturesAudio
        self.audioConfiguration = audioConfiguration
        self.audioChannelCount = audioChannelCount.map { max(1, $0) }
    }
}

/// One host capture startup request.
struct MirageHostCaptureRequest: Equatable, Sendable {
    let source: MirageHostCaptureSource
    let configuration: MirageHostCaptureConfiguration

    init(source: MirageHostCaptureSource, configuration: MirageHostCaptureConfiguration) {
        self.source = source
        self.configuration = configuration
    }
}

/// Host encoder configuration expressed without VideoToolbox session objects.
struct MirageHostEncoderConfiguration: Equatable, Sendable {
    let codec: MirageMedia.MirageVideoCodec
    let colorDepth: MirageMedia.MirageStreamColorDepth
    let targetFrameRate: Int
    let bitrateBps: Int
    let maximumInFlightFrames: Int
    let rateControlStrategy: MirageMedia.MirageEncoderRateControlStrategy
    let lowPowerModeEnabled: Bool

    init(
        codec: MirageMedia.MirageVideoCodec,
        colorDepth: MirageMedia.MirageStreamColorDepth,
        targetFrameRate: Int,
        bitrateBps: Int,
        maximumInFlightFrames: Int,
        rateControlStrategy: MirageMedia.MirageEncoderRateControlStrategy,
        lowPowerModeEnabled: Bool
    ) {
        self.codec = codec
        self.colorDepth = colorDepth
        self.targetFrameRate = max(1, targetFrameRate)
        self.bitrateBps = max(1, bitrateBps)
        self.maximumInFlightFrames = max(1, maximumInFlightFrames)
        self.rateControlStrategy = rateControlStrategy
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

/// Target coordinate space for host input injection.
enum MirageHostInputTarget: Hashable, Sendable {
    case window(MirageMedia.MirageWindow)
    case desktop(displayID: MirageHostDisplayID?)
}

/// Host audio capture configuration expressed without ScreenCaptureKit or CoreAudio types.
struct MirageHostAudioCaptureConfiguration: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let excludesCurrentProcessAudio: Bool
    let displayID: MirageHostDisplayID?

    init(
        sampleRate: Double,
        channelCount: Int,
        excludesCurrentProcessAudio: Bool,
        displayID: MirageHostDisplayID? = nil
    ) {
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.displayID = displayID
    }
}

/// One requested display-mirroring mutation.
struct MirageHostDisplayMirroringRequest: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let mirroredDisplayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID, mirroredDisplayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.mirroredDisplayID = mirroredDisplayID
    }
}

/// Result from applying a batch of host display-mirroring mutations.
struct MirageHostDisplayMirroringResult: Equatable, Sendable {
    let completed: Bool
    let committedDisplayIDs: [CGDirectDisplayID]
    let failedDisplayErrors: [CGDirectDisplayID: String]
    let failureDescription: String?

    init(
        completed: Bool,
        committedDisplayIDs: [CGDirectDisplayID],
        failedDisplayErrors: [CGDirectDisplayID: String] = [:],
        failureDescription: String? = nil
    ) {
        self.completed = completed
        self.committedDisplayIDs = committedDisplayIDs
        self.failedDisplayErrors = failedDisplayErrors
        self.failureDescription = failureDescription
    }
}

/// Captures frames for host media pipelines.
protocol MirageHostCaptureSourceBackend: Sendable {
    associatedtype Frame: Sendable
    associatedtype AudioBuffer: Sendable

    func startCapture(_ request: MirageHostCaptureRequest) async throws
    func videoFrames() -> AsyncStream<Frame>
    func audioBuffers() -> AsyncStream<AudioBuffer>
    func stopCapture() async
}

/// Enumerates and resolves host applications and windows.
protocol MirageHostWindowCatalogBackend: Sendable {
    func refreshApplications() async throws -> [MirageMedia.MirageApplication]
    func refreshWindows() async throws -> [MirageMedia.MirageWindow]
    func windows(forApplicationWithBundleIdentifier bundleIdentifier: String) async throws -> [MirageMedia.MirageWindow]
    func activateApplication(_ application: MirageMedia.MirageApplication) async throws
    func activateWindow(_ window: MirageMedia.MirageWindow) async throws
}

/// Encodes captured host frames into Mirage media batches.
protocol MirageHostEncoderBackend: Sendable {
    associatedtype Frame: Sendable

    func configure(_ configuration: MirageHostEncoderConfiguration) async throws
    func encode(_ frame: Frame, forceKeyframe: Bool) async throws -> MirageEncodedMediaBatch
    func stopEncoding() async
}

/// Creates host video encoders without exposing VideoToolbox construction to runtime code.
protocol MirageHostVideoEncoderFactoryBackend: Sendable {
    func makeVideoEncoder(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        streamKind: VideoEncoder.StreamKind,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile,
        inFlightLimit: Int?,
        maximizePowerEfficiencyEnabled: Bool
    ) -> VideoEncoder
}

/// Creates host capture engines without exposing ScreenCaptureKit construction to runtime code.
protocol MirageHostCaptureEngineFactoryBackend: Sendable {
    func makeCaptureEngine(
        configuration: MirageEncoderConfiguration,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy,
        captureFrameRate: Int?,
        usesDisplayRefreshCadence: Bool
    ) -> WindowCaptureEngine
}

/// Provides refreshed host capture content without exposing the content-list source to runtime code.
protocol MirageHostCaptureContentProviderBackend: Sendable {
    func shareableContent() async throws -> SCShareableContentWrapper
}

/// Creates per-client host audio pipelines without exposing platform audio internals to runtime code.
protocol MirageHostAudioPipelineFactoryBackend: Sendable {
    func makeAudioPipeline(
        sourceStreamID: StreamID,
        audioConfiguration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile,
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext?,
        onPacketsReady: @escaping @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    ) -> HostAudioPipeline
}

/// Owns shared host virtual display allocation, teardown, resize, and capture display resolution.
protocol MirageHostVirtualDisplayBackend: Sendable {
    var displayID: CGDirectDisplayID? { get async }
    var displaySnapshot: MirageHostVirtualDisplaySnapshot? { get async }
    var displayBounds: CGRect? { get async }
    var currentDisplayGeneration: UInt64 { get async }
    var statistics: (
        hasDisplay: Bool,
        consumerCount: Int,
        resolution: CGSize?,
        dedicatedDisplayCount: Int
    ) { get async }

    func acquireDisplayForConsumer(
        _ consumer: MirageHostVirtualDisplayConsumer,
        resolution: CGSize?,
        refreshRate: Int,
        colorSpace: MirageMedia.MirageColorSpace,
        allowActiveUpdate: Bool,
        creationPolicy: MirageHostVirtualDisplayCreationPolicy,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostVirtualDisplaySnapshot

    func releaseDisplayForConsumer(_ consumer: MirageHostVirtualDisplayConsumer) async

    func updateDisplayResolution(
        for consumer: MirageHostVirtualDisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int,
        resizeRequest: MirageHostVirtualDisplayResizeRequest?,
        allowRecreation: Bool
    ) async throws -> MirageHostDisplayResolutionUpdateResult

    func updateSharedDisplayObservedResolution(
        displayID: CGDirectDisplayID,
        resolution: CGSize
    ) async -> MirageHostVirtualDisplaySnapshot?

    func findCaptureDisplay(
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay

    func findCaptureDisplay(
        displayID: CGDirectDisplayID,
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    ) async throws -> MirageHostCaptureDisplay

    func findMainCaptureDisplay() async throws -> MirageHostCaptureDisplay

    func validateDisplayCadence(
        _ snapshot: MirageHostVirtualDisplaySnapshot,
        targetFrameRate: Int
    ) async -> MirageHostVirtualDisplayCadenceValidation

    func currentDisplayModeSizes(_ displayID: CGDirectDisplayID) -> MirageHostDisplayModeSizes?

    func displayBounds(_ displayID: CGDirectDisplayID) -> CGRect

    func displayBounds(
        _ displayID: CGDirectDisplayID,
        knownResolution: CGSize
    ) -> CGRect

    func displayVisibleBounds(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect

    func displayCaptureSourceRect(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect?
    ) -> CGRect

    func displayColorSpaceValidation(
        observedColorSpace: CGColorSpace,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult

    func displayColorSpaceValidation(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageMedia.MirageColorSpace
    ) -> MirageHostDisplayColorSpaceValidationResult

    func isMirageDisplay(_ displayID: CGDirectDisplayID) -> Bool
    func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool
    func onlineDisplayIDs() -> [CGDirectDisplayID]
    func mirroredDisplay(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID
    func displaysToMirror(excludingDisplayID displayID: CGDirectDisplayID) -> [CGDirectDisplayID]
    func space(for displayID: CGDirectDisplayID) -> CGSSpaceID
    func invalidateAllPersistentSerials()
    func withDisplayMutation<T: Sendable>(
        kind: VirtualDisplayMutationKind,
        operation: @MainActor () async -> T
    ) async -> T
    func applyDisplayMirroring(
        _ requests: [MirageHostDisplayMirroringRequest]
    ) async -> MirageHostDisplayMirroringResult
    func windowSpaces(for windowID: WindowID) -> [CGSSpaceID]
    func moveWindowToSpace(_ windowID: WindowID, spaceID: CGSSpaceID)
    func prepareWindowForMirroredCapture(
        _ windowID: WindowID,
        owner: WindowSpaceManager.WindowBindingOwner?
    ) async throws
    func moveWindow(
        _ windowID: WindowID,
        toSpaceID spaceID: CGSSpaceID,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        targetContentAspectRatio: CGFloat?,
        owner: WindowSpaceManager.WindowBindingOwner?
    ) async throws
    func restoreWindow(
        _ windowID: WindowID,
        expectedOwner: WindowSpaceManager.WindowBindingOwner?
    ) async throws
    func restoreWindowSilently(
        _ windowID: WindowID,
        expectedOwner: WindowSpaceManager.WindowBindingOwner?
    ) async
    func centerWindow(_ windowID: WindowID, on displayBounds: CGRect) async
    func resizeWindow(_ windowID: WindowID, to size: CGSize) async -> Bool
    func resizeWindowWithAccessibilityResult(
        _ windowID: WindowID,
        to size: CGSize
    ) async -> WindowAccessibilityResizeResult
    func claimedWindowIDsForActiveOwners(activeStreamIDs: Set<StreamID>) async -> Set<WindowID>
    func restoreAllWindowsOwned(by streamID: StreamID) async

    func setGenerationChangeHandler(
        _ handler: (@Sendable (MirageHostVirtualDisplaySnapshot, UInt64) -> Void)?
    ) async

    func destroyAllAndClear() async
    func resetVirtualDisplayIdentity() async throws
}

/// Injects input into host applications or desktops.
protocol MirageHostInputInjectionBackend: Sendable {
    func inject(
        _ event: MirageInput.MirageInputEvent,
        target: MirageHostInputTarget,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) async throws
    func performSystemAction(_ request: MirageInput.MirageHostSystemActionRequest) async throws
    @discardableResult func closeWindow(_ window: MirageMedia.MirageWindow) async throws -> HostWindowCloseAttemptResult
    func pressBlockingAlertAction(
        in window: MirageMedia.MirageWindow,
        actionIndex: Int,
        fallbackTitle: String
    ) async throws -> Bool
}

extension MirageHostInputInjectionBackend {
    func inject(_ event: MirageInput.MirageInputEvent, target: MirageHostInputTarget) async throws {
        try await inject(event, target: target, deferredInjectionValidator: nil)
    }
}

/// Captures host audio independently from the video capture backend.
protocol MirageHostAudioCaptureBackend: Sendable {
    associatedtype AudioBuffer: Sendable

    func startAudioCapture(_ configuration: MirageHostAudioCaptureConfiguration) async throws
    func audioBuffers() -> AsyncStream<AudioBuffer>
    func stopAudioCapture() async
}

/// Aggregates the host platform responsibilities needed by host runtime logic.
struct MirageHostPlatformBackend<
    CaptureSource: MirageHostCaptureSourceBackend,
    WindowCatalog: MirageHostWindowCatalogBackend,
    Encoder: MirageHostEncoderBackend,
    InputInjection: MirageHostInputInjectionBackend,
    AudioCapture: MirageHostAudioCaptureBackend
>: Sendable where CaptureSource.Frame == Encoder.Frame, CaptureSource.AudioBuffer == AudioCapture.AudioBuffer {
    let captureSource: CaptureSource
    let windowCatalog: WindowCatalog
    let encoder: Encoder
    let inputInjection: InputInjection
    let audioCapture: AudioCapture

    init(
        captureSource: CaptureSource,
        windowCatalog: WindowCatalog,
        encoder: Encoder,
        inputInjection: InputInjection,
        audioCapture: AudioCapture
    ) {
        self.captureSource = captureSource
        self.windowCatalog = windowCatalog
        self.encoder = encoder
        self.inputInjection = inputInjection
        self.audioCapture = audioCapture
    }
}
#endif
