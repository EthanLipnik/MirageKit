//
//  HostDesktopStreamTerminationTrackerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Desktop Stream Termination Tracker")
struct HostDesktopStreamTerminationTrackerTests {
    @Test("Termination markers are suppressed for debug bundle identifiers")
    func suppressesTerminationMarkersForDebugBundles() {
        #expect(
            !HostDesktopStreamTerminationTracker.shouldTrackTerminationMarkers(
                bundleIdentifier: "com.ethanlipnik.Mirage-Host-Debug"
            )
        )
        #expect(
            HostDesktopStreamTerminationTracker.shouldTrackTerminationMarkers(
                bundleIdentifier: "com.ethanlipnik.Mirage-Host"
            )
        )
        #expect(
            HostDesktopStreamTerminationTracker.shouldTrackTerminationMarkers(
                bundleIdentifier: nil
            )
        )
    }

    @Test("Unclean termination reporting requires a prior packet from a different run")
    func requiresPriorPacketFromDifferentRun() {
        #expect(
            !HostDesktopStreamTerminationTracker.shouldReportUncleanTermination(
                currentRunID: "current",
                markerRunID: "current",
                firstPacketSentAtUnix: 123
            )
        )
        #expect(
            !HostDesktopStreamTerminationTracker.shouldReportUncleanTermination(
                currentRunID: "current",
                markerRunID: "previous",
                firstPacketSentAtUnix: nil
            )
        )
        #expect(
            HostDesktopStreamTerminationTracker.shouldReportUncleanTermination(
                currentRunID: "current",
                markerRunID: "previous",
                firstPacketSentAtUnix: 123
            )
        )
    }
}
#endif
