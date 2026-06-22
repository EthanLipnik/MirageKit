//
//  MacOSHostPlatformBackends.swift
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
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Live macOS implementation of the host window and application catalog backend.
final class MacOSHostWindowCatalogBackend: @unchecked Sendable, MirageHostWindowCatalogBackend {
    private let windowActivator: WindowActivator
    private let captureContentProviderBackend: any MirageHostCaptureContentProviderBackend

    init(
        windowActivator: WindowActivator = .forCurrentEnvironment(),
        captureContentProviderBackend: any MirageHostCaptureContentProviderBackend =
            MacOSHostCaptureContentProviderBackend()
    ) {
        self.windowActivator = windowActivator
        self.captureContentProviderBackend = captureContentProviderBackend
    }

    func refreshApplications() async throws -> [MirageMedia.MirageApplication] {
        let windows = try await refreshWindows()
        var applicationsByKey: [String: MirageMedia.MirageApplication] = [:]

        for window in windows {
            guard let application = window.application else { continue }
            let key = "\(application.id):\(application.bundleIdentifier ?? "")"
            applicationsByKey[key] = application
        }

        return applicationsByKey.values.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func refreshWindows() async throws -> [MirageMedia.MirageWindow] {
        let contentWrapper = try await captureContentProviderBackend.shareableContent()
        let content = contentWrapper.content
        let metadata = await Task.detached { fetchWindowMetadata() }.value
        let windows = content.windows.compactMap { window in
            Self.window(from: window, metadata: metadata)
        }
        let filteredWindows = detectAndCollapseTabGroups(windows, metadata: metadata)

        return filteredWindows.sorted { lhs, rhs in
            (lhs.application?.name ?? "").localizedStandardCompare(rhs.application?.name ?? "") == .orderedAscending
        }
    }

    func windows(forApplicationWithBundleIdentifier bundleIdentifier: String) async throws -> [MirageMedia.MirageWindow] {
        let catalog = try await AppStreamWindowCatalog.catalog(
            for: [bundleIdentifier],
            captureContentProviderBackend: captureContentProviderBackend
        )
        return catalog[bundleIdentifier.lowercased(), default: []].map(\.window)
    }

    func activateApplication(_ application: MirageMedia.MirageApplication) async throws {
        if let runningApplication = NSRunningApplication(processIdentifier: application.id) {
            runningApplication.activate()
            return
        }

        guard let bundleIdentifier = application.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    func activateWindow(_ window: MirageMedia.MirageWindow) async throws {
        guard let application = window.application else { return }

        let result = windowActivator.activate(
            app: application,
            axWindow: Self.findAXWindow(for: window)
        )
        switch result {
        case let .success(method):
            MirageLogger.host("Window activated via \(method)")
        case let .partialSuccess(method, message):
            MirageLogger.host("Window partially activated via \(method): \(message)")
        case let .failure(_, error):
            MirageLogger.error(.host, "Window activation failed: \(error)")
        }
    }

    private static func window(
        from scWindow: SCWindow,
        metadata: [CGWindowID: WindowListMetadata]
    ) -> MirageMedia.MirageWindow? {
        guard scWindow.frame.width >= 200,
              scWindow.frame.height >= 150,
              let title = scWindow.title,
              !title.isEmpty,
              scWindow.windowLayer == 0,
              let scApp = scWindow.owningApplication else {
            return nil
        }

        if let windowMeta = metadata[CGWindowID(scWindow.windowID)], windowMeta.alpha < 0.01 {
            return nil
        }

        let app = MirageMedia.MirageApplication(
            id: scApp.processID,
            bundleIdentifier: scApp.bundleIdentifier,
            name: scApp.applicationName,
            iconData: nil
        )

        return MirageMedia.MirageWindow(
            id: WindowID(scWindow.windowID),
            title: title,
            application: app,
            frame: scWindow.frame,
            isOnScreen: scWindow.isOnScreen,
            windowLayer: Int(scWindow.windowLayer)
        )
    }

    private static func findAXWindow(for window: MirageMedia.MirageWindow) -> AXUIElement? {
        guard let app = window.application else {
            MirageLogger.host("Window has no associated application")
            return nil
        }

        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            MirageLogger.host("Process \(app.id) (\(app.name)) is no longer running")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.id)
        let axWindows = HostAccessibilityWindowLookup.windows(in: appElement)

        guard !axWindows.isEmpty else {
            MirageLogger.host("AX windows query returned no windows for '\(app.name)' (PID: \(app.id))")
            return nil
        }

        if let exactWindow = HostAccessibilityWindowLookup.window(matching: window.id, in: axWindows) {
            return exactWindow
        }

        if axWindows.count == 1 { return axWindows.first }

        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        for axWindow in axWindows {
            guard let position = HostAccessibilityWindowLookup.position(of: axWindow) else { continue }
            if abs(position.x - windowX) < 10, abs(position.y - windowY) < 10 { return axWindow }
        }

        return axWindows.first
    }
}

/// Live macOS implementation of host capture content discovery.
struct MacOSHostCaptureContentProviderBackend: MirageHostCaptureContentProviderBackend {
    func shareableContent() async throws -> SCShareableContentWrapper {
        let content = try await SCShareableContent.mirageHostContent()
        return SCShareableContentWrapper(content: content)
    }
}

/// Live macOS implementation of host input injection.
final class MacOSHostInputInjectionBackend: @unchecked Sendable, MirageHostInputInjectionBackend {
    private let inputController: MirageHostInputController

    init(inputController: MirageHostInputController = MirageHostInputController()) {
        self.inputController = inputController
    }

    func inject(
        _ event: MirageInput.MirageInputEvent,
        target: MirageHostInputTarget,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) async throws {
        inputController.handleInputEvent(
            event,
            window: window(for: target),
            deferredInjectionValidator: deferredInjectionValidator
        )
    }

    func performSystemAction(_ request: MirageInput.MirageHostSystemActionRequest) async throws {
        inputController.executeHostSystemAction(request)
    }

    @discardableResult func closeWindow(_ window: MirageMedia.MirageWindow) async throws -> HostWindowCloseAttemptResult {
        await inputController.attemptCloseWindowAndExtractBlockingAlert(
            windowID: window.id,
            app: window.application
        )
    }

    func pressBlockingAlertAction(
        in window: MirageMedia.MirageWindow,
        actionIndex: Int,
        fallbackTitle: String
    ) async throws -> Bool {
        await inputController.pressBlockingAlertAction(
            windowID: window.id,
            app: window.application,
            actionIndex: actionIndex,
            fallbackTitle: fallbackTitle
        )
    }

    private func window(for target: MirageHostInputTarget) -> MirageMedia.MirageWindow {
        switch target {
        case let .window(window):
            return window
        case let .desktop(displayID):
            let resolvedDisplayID = CGDirectDisplayID(displayID?.rawValue ?? CGMainDisplayID())
            return MirageMedia.MirageWindow(
                id: 0,
                title: nil,
                application: nil,
                frame: CGDisplayBounds(resolvedDisplayID),
                isOnScreen: true,
                windowLayer: 0
            )
        }
    }
}

/// Live macOS implementation of host video encoder construction.
struct MacOSHostVideoEncoderFactoryBackend: MirageHostVideoEncoderFactoryBackend {
    func makeVideoEncoder(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency,
        streamKind: VideoEncoder.StreamKind = .window,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        inFlightLimit: Int? = nil,
        maximizePowerEfficiencyEnabled: Bool = false
    ) -> VideoEncoder {
        VideoEncoder(
            configuration: configuration,
            latencyMode: latencyMode,
            streamKind: streamKind,
            mediaPathProfile: mediaPathProfile,
            inFlightLimit: inFlightLimit,
            maximizePowerEfficiencyEnabled: maximizePowerEfficiencyEnabled
        )
    }
}

/// Live macOS implementation of host capture engine construction.
struct MacOSHostCaptureEngineFactoryBackend: MirageHostCaptureEngineFactoryBackend {
    func makeCaptureEngine(
        configuration: MirageEncoderConfiguration,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline,
        latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy = .freshestFrame,
        captureFrameRate: Int? = nil,
        usesDisplayRefreshCadence: Bool = false
    ) -> WindowCaptureEngine {
        WindowCaptureEngine(
            configuration: configuration,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
    }
}

/// Live macOS implementation of host audio pipeline construction.
struct MacOSHostAudioPipelineFactoryBackend: MirageHostAudioPipelineFactoryBackend {
    func makeAudioPipeline(
        sourceStreamID: StreamID,
        audioConfiguration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile,
        maxPayloadSize: Int,
        mediaSecurityContext: MirageMediaSecurityContext?,
        onPacketsReady: @escaping @Sendable ([Data], EncodedAudioFrame, StreamID) async -> Void
    ) -> HostAudioPipeline {
        HostAudioPipeline(
            sourceStreamID: sourceStreamID,
            audioConfiguration: audioConfiguration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onPacketsReady: onPacketsReady
        )
    }
}

#endif
