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
}
#endif
