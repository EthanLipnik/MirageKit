//
//  HostAudioLivenessPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Audio Liveness Policy")
struct HostAudioLivenessPolicyTests {
    @Test("Missing first sample retries once then fails")
    func missingFirstSampleRetriesOnceThenFails() {
        #expect(
            HostAudioFirstSampleWatchdogPolicy.decision(
                audioEnabled: true,
                pipelineActive: true,
                sourceMatches: true,
                lastSampleTime: nil,
                activationTime: 10,
                retryAttempted: false
            ) == .retryCapture
        )
        #expect(
            HostAudioFirstSampleWatchdogPolicy.decision(
                audioEnabled: true,
                pipelineActive: true,
                sourceMatches: true,
                lastSampleTime: nil,
                activationTime: 10,
                retryAttempted: true
            ) == .fail
        )
    }

    @Test("Observed first sample disables watchdog action")
    func observedFirstSampleDisablesWatchdogAction() {
        #expect(
            HostAudioFirstSampleWatchdogPolicy.decision(
                audioEnabled: true,
                pipelineActive: true,
                sourceMatches: true,
                lastSampleTime: 11,
                activationTime: 10,
                retryAttempted: false
            ) == .ignore
        )
    }
}
#endif
