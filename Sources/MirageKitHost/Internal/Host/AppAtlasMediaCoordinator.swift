//
//  AppAtlasMediaCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
/// Coordinates logical app windows, auxiliary overlays, and encoded app-atlas media frames for one client.
actor AppAtlasMediaCoordinator {
    /// Shared media stream that carries the packed atlas surface.
    let mediaStreamID: StreamID

    /// Host stream context and fixed encoder settings used by the atlas media stream.
    let context: StreamContext
    let encoderConfig: MirageEncoderConfiguration
    let latencyMode: MirageStreamLatencyMode
    let hostBufferingPolicy: MirageHostBufferingPolicy
    let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
    let targetFrameRate: Int

    /// Packet and control-message hooks supplied by the owning host service.
    private let sendPacket: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    private let onSendError: @Sendable (Error) -> Void
    private let sendMediaUpdate: @MainActor @Sendable (AppAtlasMediaUpdateMessage) async -> Void
    let publishOverlayRegions: @MainActor @Sendable (StreamID, [AppStreamInputOverlayRegion]) async -> Void

    /// Custom stream sink and startup marker for the single packed atlas stream.
    var frameSink: MirageCustomStreamFrameSink?
    private var startupAttemptID: UUID?

    /// ScreenCaptureKit capture contexts keyed by real host window ID.
    var capturesByWindowID: [WindowID: AppAtlasWindowCaptureContext] = [:]
    var auxiliaryCapturesByWindowID: [WindowID: AppAtlasWindowCaptureContext] = [:]

    /// Logical app-stream identity maps that connect client stream IDs to host windows.
    var logicalWindowsByWindowID: [WindowID: AppAtlasLogicalWindow] = [:]
    var windowIDByStreamID: [StreamID: WindowID] = [:]

    /// Latest primary and auxiliary frames waiting to be composited into the atlas.
    var latestFramesByWindowID: [WindowID: CapturedFrame] = [:]
    var latestAuxiliaryFramesByWindowID: [WindowID: CapturedFrame] = [:]

    /// Auxiliary overlay geometry keyed by auxiliary window and grouped by parent window.
    var auxiliaryOverlaysByWindowID: [WindowID: AppAtlasAuxiliaryOverlay] = [:]
    var auxiliaryWindowIDsByParentWindowID: [WindowID: Set<WindowID>] = [:]

    /// Current compositor, layout cache, and composition loop lifecycle.
    var compositor: AppAtlasFrameCompositor?
    private var layoutEpoch: UInt64 = 0
    var currentLayout: AppAtlasLayout.Result?
    private var currentPublicLayout: MirageAppAtlasLayout?
    var compositionTask: Task<Void, Never>?
    var isStopped = false

    init(
        mediaStreamID: StreamID,
        context: StreamContext,
        encoderConfig: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        targetFrameRate: Int,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: @escaping @Sendable (Error) -> Void,
        sendMediaUpdate: @escaping @MainActor @Sendable (AppAtlasMediaUpdateMessage) async -> Void,
        publishOverlayRegions: @escaping @MainActor @Sendable (StreamID, [AppStreamInputOverlayRegion]) async -> Void
    ) {
        self.mediaStreamID = mediaStreamID
        self.context = context
        self.encoderConfig = encoderConfig
        self.latencyMode = latencyMode
        self.hostBufferingPolicy = hostBufferingPolicy
        self.capturePressureProfile = capturePressureProfile
        self.targetFrameRate = max(1, targetFrameRate)
        self.sendPacket = sendPacket
        self.onSendError = onSendError
        self.sendMediaUpdate = sendMediaUpdate
        self.publishOverlayRegions = publishOverlayRegions
    }

    /// Whether the coordinator currently has no logical windows attached.
    var isEmpty: Bool {
        logicalWindowsByWindowID.isEmpty
    }

    /// Returns logical app-stream identifiers currently represented by the atlas.
    func logicalStreamIDs() -> [StreamID] {
        logicalWindowsByWindowID.values.map(\.streamID).sorted()
    }

    /// Adds a logical window to the atlas and starts its capture.
    func addWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper
    ) async throws -> AppAtlasWindowAttachment {
        try await attachWindow(
            streamID: streamID,
            window: window,
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            replacingExistingStreamBinding: false,
            reason: "window added"
        )
    }

    /// Replaces an existing stream binding with a new host window.
    func replaceWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper
    ) async throws -> AppAtlasWindowAttachment {
        try await attachWindow(
            streamID: streamID,
            window: window,
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            replacingExistingStreamBinding: true,
            reason: "window replaced"
        )
    }

    /// Shared attach path for new logical windows and window replacement.
    private func attachWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        replacingExistingStreamBinding: Bool,
        reason: String
    ) async throws -> AppAtlasWindowAttachment {
        guard !isStopped else { throw CancellationError() }

        let windowID = window.id
        if let existing = logicalWindowsByWindowID[windowID] {
            guard existing.streamID == streamID else {
                throw MirageError.protocolError("App-atlas window \(windowID) is already bound to stream \(existing.streamID)")
            }
            return try await attachment(for: existing)
        }
        if !replacingExistingStreamBinding, let existingWindowID = windowIDByStreamID[streamID] {
            throw MirageError.protocolError("App-atlas stream \(streamID) is already bound to window \(existingWindowID)")
        }
        if capturesByWindowID[windowID] != nil {
            throw MirageError.protocolError("App-atlas window \(windowID) capture is already starting")
        }

        let captureContext = AppAtlasWindowCaptureContext()
        let target = streamTargetDimensions(windowFrame: windowWrapper.window.frame)
        let pixelSize = CGSize(width: target.width, height: target.height)
        var logicalWindow = AppAtlasLogicalWindow(
            streamID: streamID,
            windowID: windowID,
            title: window.title,
            screenFrame: window.frame,
            pointSize: window.frame.size,
            pixelSize: pixelSize,
            sourceRect: CGRect(origin: .zero, size: pixelSize)
        )

        capturesByWindowID[windowID] = captureContext
        do {
            try await captureContext.startCapture(
                windowWrapper: windowWrapper,
                applicationWrapper: applicationWrapper,
                displayWrapper: displayWrapper,
                encoderConfig: encoderConfig,
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy,
                capturePressureProfile: capturePressureProfile,
                targetFrameRate: targetFrameRate,
                onFrame: { [weak self] frame in
                    Task(priority: .userInitiated) {
                        await self?.recordFrame(frame, windowID: windowID)
                    }
                }
            )
        } catch {
            capturesByWindowID.removeValue(forKey: windowID)
            await captureContext.stop()
            throw error
        }

        guard !isStopped else {
            capturesByWindowID.removeValue(forKey: windowID)
            await captureContext.stop()
            throw CancellationError()
        }

        let oldWindowID = replacingExistingStreamBinding ? windowIDByStreamID[streamID] : nil
        let oldLogicalWindow = oldWindowID.flatMap { logicalWindowsByWindowID[$0] }
        let oldLatestFrame = oldWindowID.flatMap { latestFramesByWindowID[$0] }
        let oldCapture = oldWindowID.flatMap { capturesByWindowID.removeValue(forKey: $0) }
        if let oldWindowID {
            await removeAuxiliaryOverlays(parentWindowID: oldWindowID, publishEmptyForStreamID: streamID)
            logicalWindowsByWindowID.removeValue(forKey: oldWindowID)
            latestFramesByWindowID.removeValue(forKey: oldWindowID)
        }

        if let latestFrame = latestFramesByWindowID[windowID] {
            let latestPixelSize = Self.pixelSize(for: latestFrame)
            logicalWindow.pixelSize = latestPixelSize
            logicalWindow.sourceRect = Self.normalizedSourceRect(
                contentRect: latestFrame.info.contentRect,
                pixelSize: latestPixelSize
            )
        }

        logicalWindowsByWindowID[windowID] = logicalWindow
        windowIDByStreamID[streamID] = windowID

        do {
            try await recomputeLayoutAndNotify(reason: reason)
            startCompositionLoopIfNeeded()
        } catch {
            capturesByWindowID.removeValue(forKey: windowID)
            logicalWindowsByWindowID.removeValue(forKey: windowID)
            latestFramesByWindowID.removeValue(forKey: windowID)
            if let oldWindowID, let oldCapture {
                capturesByWindowID[oldWindowID] = oldCapture
                if let oldLogicalWindow {
                    logicalWindowsByWindowID[oldWindowID] = oldLogicalWindow
                }
                if let oldLatestFrame {
                    latestFramesByWindowID[oldWindowID] = oldLatestFrame
                }
                windowIDByStreamID[streamID] = oldWindowID
            } else {
                windowIDByStreamID.removeValue(forKey: streamID)
            }
            await captureContext.stop()
            throw error
        }

        await oldCapture?.stop()
        return try await attachment(for: logicalWindow)
    }

    /// Removes one logical stream and its parented auxiliary overlays.
    func removeWindow(streamID: StreamID) async {
        guard let windowID = windowIDByStreamID.removeValue(forKey: streamID) else { return }
        await removeAuxiliaryOverlays(parentWindowID: windowID, publishEmptyForStreamID: streamID)
        logicalWindowsByWindowID.removeValue(forKey: windowID)
        latestFramesByWindowID.removeValue(forKey: windowID)
        let capture = capturesByWindowID.removeValue(forKey: windowID)
        await capture?.stop()
        do {
            try await recomputeLayoutAndNotify(reason: "window removed")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update app-atlas layout after window removal: ")
        }
    }

    /// Stops all captures, clears layout state, and shuts down the media stream context.
    func stop() async {
        isStopped = true
        compositionTask?.cancel()
        compositionTask = nil
        let captures = capturesByWindowID.values
        let auxiliaryCaptures = auxiliaryCapturesByWindowID.values
        let logicalStreamIDs = logicalWindowsByWindowID.values.map(\.streamID)
        capturesByWindowID.removeAll()
        auxiliaryCapturesByWindowID.removeAll()
        logicalWindowsByWindowID.removeAll()
        windowIDByStreamID.removeAll()
        latestFramesByWindowID.removeAll()
        latestAuxiliaryFramesByWindowID.removeAll()
        auxiliaryOverlaysByWindowID.removeAll()
        auxiliaryWindowIDsByParentWindowID.removeAll()
        frameSink = nil
        compositor = nil
        currentLayout = nil
        currentPublicLayout = nil
        for capture in captures {
            await capture.stop()
        }
        for capture in auxiliaryCaptures {
            await capture.stop()
        }
        for streamID in logicalStreamIDs {
            await publishOverlayRegions(streamID, [])
        }
        await context.stop()
    }

    /// Returns the current public atlas layout, if the media stream is active.
    func atlasLayouts() -> [MirageAppAtlasLayout] {
        currentPublicLayout.map { [$0] } ?? []
    }

    /// Stores the latest primary window frame and recomputes layout when source geometry changes.
    private func recordFrame(_ frame: CapturedFrame, windowID: WindowID) async {
        latestFramesByWindowID[windowID] = frame
        let pixelSize = Self.pixelSize(for: frame)
        let sourceRect = Self.normalizedSourceRect(
            contentRect: frame.info.contentRect,
            pixelSize: pixelSize
        )
        guard var logicalWindow = logicalWindowsByWindowID[windowID],
              logicalWindow.pixelSize != pixelSize || logicalWindow.sourceRect != sourceRect else {
            return
        }

        logicalWindow.pixelSize = pixelSize
        logicalWindow.sourceRect = sourceRect
        logicalWindowsByWindowID[windowID] = logicalWindow
        recomputeAuxiliaryOverlayGeometry(parentWindowID: windowID)
        await publishAuxiliaryOverlayRegions(parentStreamID: logicalWindow.streamID, parentWindowID: windowID)
        do {
            try await recomputeLayoutAndNotify(reason: "capture geometry changed")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update app-atlas layout after capture resize: ")
        }
    }

    /// Recomputes the packed layout and sends an atlas media update when it changes.
    private func recomputeLayoutAndNotify(reason: String) async throws {
        let windows = logicalWindowsByWindowID.values
            .sorted { lhs, rhs in lhs.streamID < rhs.streamID }
            .map { window in
                AppAtlasLayout.Window(
                    id: window.windowID,
                    sourceRect: window.sourceRect
                )
            }
        let nextLayout = AppAtlasLayout.nativePackedLayout(windows: windows)
        guard !nextLayout.placements.isEmpty else {
            currentLayout = nil
            currentPublicLayout = nil
            return
        }

        let previousCanvas = currentLayout?.canvasSize ?? .zero
        let previousPlacements = currentLayout?.placements ?? []
        let canvasChanged = previousCanvas != nextLayout.canvasSize
        let placementsChanged = previousPlacements != nextLayout.placements
        guard canvasChanged || placementsChanged else { return }

        layoutEpoch &+= 1
        currentLayout = nextLayout
        if frameSink == nil {
            try await startMediaStreamIfNeeded(pixelSize: nextLayout.canvasSize)
        } else if canvasChanged {
            try await context.applyAppAtlasDimensionsIfNeeded(pixelSize: nextLayout.canvasSize)
        }

        let publicLayout = nextLayout.makePublicLayout(
            mediaStreamID: mediaStreamID,
            layoutEpoch: layoutEpoch,
            focusedWindowID: logicalWindowsByWindowID.values.min { $0.streamID < $1.streamID }?.windowID
        )
        currentPublicLayout = publicLayout
        try await sendCurrentMediaUpdate(layout: publicLayout)
        MirageLogger.host(
            "App atlas layout updated mediaStream=\(mediaStreamID) reason=\(reason) " +
                "epoch=\(layoutEpoch) size=\(publicLayout.width)x\(publicLayout.height) regions=\(publicLayout.regions.count)"
        )
    }

    /// Starts the shared atlas media stream the first time a non-empty layout is available.
    private func startMediaStreamIfNeeded(pixelSize: CGSize) async throws {
        guard frameSink == nil else { return }
        if startupAttemptID == nil {
            startupAttemptID = UUID()
        }
        frameSink = try await context.startAppAtlasFrameStream(
            pixelSize: pixelSize,
            sendPacket: sendPacket,
            onSendError: onSendError
        )
        await context.allowEncodingAfterRegistration()
    }

    /// Sends the current media stream parameters and atlas layout to the client.
    private func sendCurrentMediaUpdate(layout: MirageAppAtlasLayout) async throws {
        let streamStart = await context.streamStartSnapshot
        let message = AppAtlasMediaUpdateMessage(
            mediaStreamID: mediaStreamID,
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height,
            codec: streamStart.codec,
            frameRate: streamStart.targetFrameRate,
            dimensionToken: streamStart.dimensionToken,
            layoutEpoch: layout.layoutEpoch,
            acceptedPacketSize: streamStart.mediaMaxPacketSize,
            layout: layout,
            startupAttemptID: startupAttemptID ?? UUID()
        )
        await sendMediaUpdate(message)
    }

    /// Builds client-visible attachment metadata for a logical window.
    private func attachment(for window: AppAtlasLogicalWindow) async throws -> AppAtlasWindowAttachment {
        guard let layout = currentPublicLayout,
              let region = layout.region(for: window.windowID) else {
            throw MirageError.protocolError("App-atlas layout missing region for window \(window.windowID)")
        }
        return AppAtlasWindowAttachment(
            mediaStreamID: mediaStreamID,
            windowID: window.windowID,
            title: window.title,
            width: Int(max(1, window.pointSize.width.rounded())),
            height: Int(max(1, window.pointSize.height.rounded())),
            atlasRegion: region,
            atlasLayouts: [layout]
        )
    }
}
#endif
