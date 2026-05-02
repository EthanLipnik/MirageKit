//
//  MirageHostService+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Client-initiated host screenshot handling.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleHostScreenshotRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: HostScreenshotRequestMessage
        do {
            request = try message.decode(HostScreenshotRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host screenshot request: ")
            return
        }

        let result = await performHostScreenshot(request)
        do {
            try await clientContext.send(.hostScreenshotResult, content: result)
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Host screenshot result",
                sessionID: clientContext.sessionID
            )
        }
    }

    private func performHostScreenshot(
        _ request: HostScreenshotRequestMessage
    ) async -> HostScreenshotResultMessage {
        let capturedAt = Date()
        let startedLightsOutSuspension = await beginLightsOutScreenshotSuspension(
            monitorNativeScreenshotApp: false
        )
        if startedLightsOutSuspension {
            try? await Task.sleep(for: .milliseconds(80))
        }

        let result: HostScreenshotResultMessage
        do {
            let target = try await resolveAndCaptureHostScreenshotTarget(
                for: request,
                capturedAt: capturedAt
            )
            result = HostScreenshotResultMessage(
                requestID: request.requestID,
                style: request.style,
                success: true,
                source: target.captureTarget.source,
                filePath: target.savedFile.url.path,
                fileName: target.savedFile.url.lastPathComponent,
                pixelWidth: target.savedFile.pixelWidth,
                pixelHeight: target.savedFile.pixelHeight,
                byteCount: target.savedFile.byteCount,
                displayID: target.captureTarget.displayID,
                capturedAtMillisecondsSince1970: Self.millisecondsSince1970(capturedAt)
            )
            MirageLogger.host(
                "Host screenshot saved source=\(target.captureTarget.source.rawValue) style=\(request.style.rawValue) " +
                    "path=\(target.savedFile.url.path) size=\(target.savedFile.pixelWidth)x\(target.savedFile.pixelHeight) " +
                    "bytes=\(target.savedFile.byteCount)"
            )
        } catch {
            let fallbackSource = MirageHostScreenshotSource.primaryPhysicalDisplay
            result = HostScreenshotResultMessage(
                requestID: request.requestID,
                style: request.style,
                success: false,
                source: fallbackSource,
                capturedAtMillisecondsSince1970: Self.millisecondsSince1970(capturedAt),
                errorMessage: error.localizedDescription
            )
            MirageLogger.error(.host, error: error, message: "Host screenshot failed: ")
        }

        await endLightsOutScreenshotSuspensionIfNeeded(
            startedNewSuspension: startedLightsOutSuspension
        )
        return result
    }

    private func resolveAndCaptureHostScreenshotTarget(
        for request: HostScreenshotRequestMessage,
        capturedAt: Date
    ) async throws -> (captureTarget: HostScreenshotCaptureTarget, savedFile: HostScreenshotSavedFile) {
        if let activeTarget = await activeStreamScreenshotTarget(for: request) {
            do {
                let savedFile = try await HostScreenshotCapturer.captureAndSave(
                    target: activeTarget,
                    capturedAt: capturedAt
                )
                return (activeTarget, savedFile)
            } catch {
                MirageLogger.error(.host, error: error, message: "Active stream screenshot target failed; falling back: ")
            }
        }

        if let primaryTarget = HostScreenshotCapturer.primaryPhysicalDisplayTarget(
            primaryDisplayID: MirageHostWallpaperResolver.resolvedPrimaryPhysicalDisplayID()
        ) {
            let savedFile = try await HostScreenshotCapturer.captureAndSave(
                target: primaryTarget,
                capturedAt: capturedAt
            )
            return (primaryTarget, savedFile)
        }

        throw HostScreenshotError.noCaptureTarget
    }

    private func activeStreamScreenshotTarget(
        for request: HostScreenshotRequestMessage
    ) async -> HostScreenshotCaptureTarget? {
        if let streamID = request.streamID,
           let context = streamsByID[streamID],
           let target = await context.hostScreenshotCaptureTarget(style: request.style) {
            return target
        }

        if let desktopStreamContext,
           let target = await desktopStreamContext.hostScreenshotCaptureTarget(style: request.style) {
            return target
        }

        for session in activeStreams {
            guard session.id != request.streamID,
                  let context = streamsByID[session.id],
                  let target = await context.hostScreenshotCaptureTarget(style: request.style) else {
                continue
            }
            return target
        }

        return nil
    }

    private static func millisecondsSince1970(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

private extension HostScreenshotCaptureTarget {
    var displayID: CGDirectDisplayID? {
        switch filter {
        case let .display(displayID, _, _):
            return displayID
        case let .window(_, displayID):
            return displayID
        }
    }
}
#endif
