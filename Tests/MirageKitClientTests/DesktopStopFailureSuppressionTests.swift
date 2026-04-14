//
//  DesktopStopFailureSuppressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//
//  Coverage for suppressing startup-failure delivery after an explicit local desktop stop.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Loom
import Testing

#if os(macOS)
@Suite("Desktop Stop Failure Suppression")
struct DesktopStopFailureSuppressionTests {
    @MainActor
    @Test("Explicit desktop stop suppresses terminal startup failure delivery")
    func explicitDesktopStopSuppressesTerminalStartupFailureDelivery() async {
        let service = MirageClientService(deviceName: "Test Device")
        let delegate = DelegateSpy()
        let streamID: StreamID = 55

        service.delegate = delegate
        service.desktopStreamID = streamID
        service.desktopSessionID = UUID()
        service.desktopStreamMode = .unified
        service.pendingLocalDesktopStopStreamID = streamID
        service.pendingLocalDesktopStopSessionID = service.desktopSessionID

        let failure = StreamController.TerminalStartupFailure(
            reason: .startupKeyframeTimeout,
            hardRecoveryAttempts: 1,
            waitReason: "startup-hard-recovery"
        )

        await service.handleTerminalStartupFailure(failure, for: streamID)

        #expect(delegate.errorCount == 0)
        #expect(service.desktopStreamID == nil)
        #expect(service.desktopSessionID == nil)
        #expect(service.desktopStreamMode == nil)
        #expect(service.pendingLocalDesktopStopStreamID == nil)
        #expect(service.pendingLocalDesktopStopSessionID == nil)
    }
}

private final class DelegateSpy: MirageClientDelegate, @unchecked Sendable {
    private(set) var errorCount = 0

    @MainActor
    func clientService(_: MirageClientService, didUpdateWindowList _: [MirageWindow]) {}

    @MainActor
    func clientService(_: MirageClientService, didReceiveVideoPacket _: Data, forStream _: StreamID) {}

    @MainActor
    func clientService(_: MirageClientService, didDisconnectFromHost _: String) {}

    @MainActor
    func clientService(_: MirageClientService, didEncounterError _: Error) {
        errorCount += 1
    }

    @MainActor
    func clientService(
        _: MirageClientService,
        didReceiveContentBoundsUpdate _: CGRect,
        forStream _: StreamID
    ) {}

    @MainActor
    func clientService(
        _: MirageClientService,
        hostSessionStateChanged _: LoomSessionAvailability,
        requiresUserIdentifier _: Bool
    ) {}
}
#endif
