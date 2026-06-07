//
//  AppAtlasMediaCoordinatorTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import ScreenCaptureKit

/// Attachment metadata returned when a logical window joins an app-atlas media stream.
struct AppAtlasWindowAttachment {
    /// Shared media stream that carries the packed atlas surface.
    let mediaStreamID: StreamID
    /// Logical host window represented by the attachment.
    let windowID: WindowID
    /// Current host window title, if available.
    let title: String?
    /// Region width in atlas pixels.
    let width: Int
    /// Region height in atlas pixels.
    let height: Int
    /// Client-visible region occupied by the logical window.
    let atlasRegion: MirageMedia.MirageAppAtlasRegion
    /// Current atlas layouts that describe the media stream.
    let atlasLayouts: [MirageMedia.MirageAppAtlasLayout]
}

/// Owns the capture engine for one logical or auxiliary atlas window.
actor AppAtlasWindowCaptureContext {
    private(set) var captureEngine: WindowCaptureEngine?
    private var captureSourceBackend: MacOSHostCaptureSourceBackend?
    private(set) var isCapturing = false

    /// Starts window capture once and forwards captured frames to the coordinator.
    func startCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        encoderConfig: MirageEncoderConfiguration,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        targetFrameRate: Int,
        captureEngineFactoryBackend: any MirageHostCaptureEngineFactoryBackend,
        captureContentProviderBackend: any MirageHostCaptureContentProviderBackend,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void
    ) async throws {
        guard !isCapturing else { return }

        let engine = captureEngineFactoryBackend.makeCaptureEngine(
            configuration: encoderConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            captureFrameRate: targetFrameRate,
            usesDisplayRefreshCadence: false
        )
        captureEngine = engine
        let backend = MacOSHostCaptureSourceBackend(
            captureEngineFactoryBackend: captureEngineFactoryBackend,
            captureContentProviderBackend: captureContentProviderBackend
        )
        captureSourceBackend = backend
        try await backend.startCapture(
            Self.captureRequest(
                windowID: WindowID(windowWrapper.window.windowID),
                windowSize: windowWrapper.window.frame.size,
                encoderConfig: encoderConfig,
                targetFrameRate: targetFrameRate
            ),
            using: engine,
            onFrame: onFrame,
            onAudio: nil
        )
        isCapturing = true
    }

    /// Stops capture and releases the underlying window capture engine.
    func stop() async {
        guard isCapturing else {
            captureEngine = nil
            return
        }
        isCapturing = false
        if let captureSourceBackend {
            await captureSourceBackend.stopCapture()
            self.captureSourceBackend = nil
        } else {
            await captureEngine?.stopCapture()
        }
        captureEngine = nil
    }

    nonisolated static func captureRequest(
        windowID: WindowID,
        windowSize: CGSize,
        encoderConfig: MirageEncoderConfiguration,
        targetFrameRate: Int
    ) -> MirageHostCaptureRequest {
        MirageHostCaptureRequest(
            source: .window(windowID),
            configuration: MirageHostCaptureConfiguration(
                logicalSize: windowSize,
                targetFrameRate: targetFrameRate,
                queueDepth: encoderConfig.captureQueueDepth ?? 1,
                capturesAudio: false,
                audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: false)
            )
        )
    }
}

/// Mutable geometry for a primary logical window inside an app-atlas session.
struct AppAtlasLogicalWindow {
    /// Logical stream identifier exposed to app-stream clients.
    let streamID: StreamID
    /// Host window identifier backing the logical stream.
    let windowID: WindowID
    /// Latest host window title.
    var title: String?
    /// Latest host screen-space frame in points.
    var screenFrame: CGRect
    /// Latest logical size in host points.
    var pointSize: CGSize
    /// Latest captured size in pixels.
    var pixelSize: CGSize
    /// Source rectangle copied from the captured window surface.
    var sourceRect: CGRect
}

/// Parent-local auxiliary overlay metadata for sheets, popovers, and dialogs.
struct AppAtlasAuxiliaryOverlay {
    /// Auxiliary host window identifier.
    let windowID: WindowID
    /// Logical stream ID of the parent window that receives the overlay.
    var parentStreamID: StreamID
    /// Host window ID of the parent window that receives the overlay.
    var parentWindowID: WindowID
    /// Latest auxiliary window metadata.
    var window: MirageMedia.MirageWindow
    /// Whether Accessibility reports the auxiliary as focused.
    var isFocused: Bool
    /// Whether Accessibility reports the auxiliary as main.
    var isMain: Bool
    /// Whether Accessibility reports the auxiliary as modal.
    var isModal: Bool
    /// CoreGraphics window layer used for overlay ordering.
    var windowLayer: Int
    /// CoreGraphics window list order used for overlay ordering.
    var windowListOrder: Int
    /// Parent-capture destination rectangle for composition.
    var destinationRect: CGRect
    /// Parent-local input routing rectangle normalized to the parent surface.
    var normalizedInputRect: CGRect

    /// Whether this auxiliary overlay should receive keyboard input before the parent.
    var receivesKeyboardFocus: Bool {
        isFocused || isMain || isModal
    }
}
#endif
