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
@Suite("Standard Desktop Low Latency Tuning")
struct StandardDesktopLowLatencyTuningTests {
    @Test("Standard desktop lowest latency suppresses VT low-latency rate control at 6K and 720p")
    func standardDesktopLowestLatencySuppressesForAllDesktopSizes() {
        #expect(!HEVCEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 6016,
            height: 3384,
            streamKind: .desktop
        ))
        #expect(!HEVCEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .desktop
        ))
        #expect(HEVCEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 6016,
            height: 3384,
            streamKind: .desktop
        ))
        #expect(HEVCEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .desktop
        ))
    }

    @Test("Non-desktop standard lowest latency and game mode still request VT low-latency rate control")
    func nonDesktopAndGameModeStillRequestLowLatencyRateControl() {
        #expect(HEVCEncoder.standardLowLatencyVTTuningEnabled(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .window
        ))
        #expect(!HEVCEncoder.shouldApplySuppressedStandardLowLatencyThroughputTuning(
            performanceMode: .standard,
            latencyMode: .lowestLatency,
            width: 1280,
            height: 720,
            streamKind: .window
        ))

        let spec = HEVCEncoder.encoderSpecification(
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
