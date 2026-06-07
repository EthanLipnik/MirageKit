//
//  AppAtlasMediaCoordinator+Composition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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
import CoreMedia
import CoreVideo
import Foundation

#if os(macOS)

extension AppAtlasMediaCoordinator {
    /// Starts the periodic composition task that emits atlas frames at the target frame rate.
    func startCompositionLoopIfNeeded() {
        guard compositionTask == nil else { return }
        let fps = max(1, targetFrameRate)
        compositionTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let frameDuration = Duration.nanoseconds(Int64(max(1, 1_000_000_000 / UInt64(fps))))
            while !Task.isCancelled {
                await emitAtlasFrameIfPossible()
                do {
                    try await Task.sleep(for: frameDuration)
                } catch {
                    return
                }
            }
        }
    }

    /// Returns the pixel size of a captured frame.
    nonisolated static func pixelSize(for frame: CapturedFrame) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
    }

    /// Composes and submits one atlas frame when enough source frames are available.
    func emitAtlasFrameIfPossible() async {
        guard let frameSink,
              let layout = currentLayout,
              !latestFramesByWindowID.isEmpty else {
            return
        }

        do {
            if compositor == nil {
                compositor = try AppAtlasFrameCompositor()
            }
            guard let compositor else { return }
            try await context.applyAppAtlasDimensionsIfNeeded(pixelSize: layout.canvasSize)
            let framesByWindowID = try framesByCompositingAuxiliaryOverlays(using: compositor)
            let pixelBuffer = try compositor.compose(
                framesByWindowID: framesByWindowID,
                layout: layout
            )
            let presentationTime = framesByWindowID.values
                .map(\.presentationTime)
                .max { CMTimeCompare($0, $1) < 0 } ?? CMTime(
                    seconds: CFAbsoluteTimeGetCurrent(),
                    preferredTimescale: 1_000_000_000
                )
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, targetFrameRate)))
            let contentRect = CGRect(origin: .zero, size: layout.canvasSize)
            let frame = MirageCustomStreamFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                contentRect: contentRect,
                dirtyPercentage: 100,
                isIdleFrame: false
            )
            frameSink.submit(frame)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to emit app-atlas frame: ")
        }
    }
}

#endif
