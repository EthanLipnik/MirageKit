//
//  CaptureStreamOutputWatchdogTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import Testing

@Suite("Capture Stream Output Watchdog")
struct CaptureStreamOutputWatchdogTests {
    @Test("Display capture idle gap does not emit capture stall")
    func displayCaptureIdleGapDoesNotEmitCaptureStall() {
        let stallCount = Locked(0)
        let output = CaptureStreamOutput(
            onFrame: { _ in },
            onCaptureStall: { _ in stallCount.withLock { $0 += 1 } },
            windowID: 0,
            frameGapThreshold: 0.010,
            softStallThreshold: 0.020,
            hardRestartThreshold: 0.030
        )
        output.stopWatchdogTimer()

        output.updateDeliveryState(captureTime: CFAbsoluteTimeGetCurrent() - 1.0, isComplete: true)
        output.checkForFrameGap()

        #expect(stallCount.read { $0 } == 0)
        #expect(output.fallbackLock.withLock { !output.wasInFallbackMode })
    }
}
#endif
