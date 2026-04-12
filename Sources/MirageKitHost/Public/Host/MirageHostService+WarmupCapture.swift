//
//  MirageHostService+WarmupCapture.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
public extension MirageHostService {
    /// Runs a short hidden display capture to flush any follow-on screen-recording prompts.
    func performScreenRecordingWarmupCapture(
        duration: Duration = .seconds(1),
        frameRate: Int = 60
    ) async throws {
        let display = try await findMainSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
        let captureEngine = WindowCaptureEngine(
            configuration: encoderConfig,
            latencyMode: .lowestLatency,
            captureFrameRate: max(1, frameRate)
        )

        do {
            try await captureEngine.startDisplayCapture(
                display: display.display,
                showsCursor: false,
                onFrame: { _ in }
            )
            try? await Task.sleep(for: duration)
            await captureEngine.stopCapture()
        } catch {
            await captureEngine.stopCapture()
            throw error
        }
    }
}
#endif
