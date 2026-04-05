//
//  StandardDesktopLowLatencyTuningTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/6/26.
//

@testable import MirageKitHost
import MirageKit
import Testing
import VideoToolbox

#if os(macOS)
@Suite("Standard Low Latency Tuning")
struct StandardDesktopLowLatencyTuningTests {
    @Test("Standard lowest latency suppresses VT low-latency rate control for desktop and window streams")
    func standardLowestLatencySuppressesRateControlForDesktopAndWindowStreams() {
        #expect(!VideoEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 6016,
            height: 3384,
            streamKind: .desktop
        ))
        #expect(!VideoEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .desktop
        ))
        #expect(VideoEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 6016,
            height: 3384,
            streamKind: .desktop
        ))
        #expect(VideoEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .desktop
        ))
        #expect(!VideoEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .window
        ))
        #expect(VideoEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .window
        ))
    }

    @Test("Game mode still requests VT low-latency rate control")
    func gameModeStillRequestsLowLatencyRateControl() {
        let spec = VideoEncoder.encoderSpecification(
            for: .game,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .desktop
        )
        #expect((spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] as? Bool) == true)
    }
}
#endif
