//
//  ControlUpdatePolicySuppressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Interactive-streaming control-update suppression coverage.
//

@testable import MirageKitClient
import CoreGraphics
import Foundation
import MirageKit
import Testing
import MirageMedia
import MirageWire

@Suite("Control Update Policy Suppression")
struct ControlUpdatePolicySuppressionTests {
    @Test("Deferred refresh requirements are tracked and consumed once")
    func deferredRefreshRequirementsConsumeOnce() async throws {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let appListMessage = try MirageWire.ControlMessage(
            type: .appListComplete,
            content: MirageWire.AppListCompleteMessage(requestID: UUID(), totalAppCount: 0)
        )
        let windowListMessage = try MirageWire.ControlMessage(
            type: .windowList,
            content: MirageWire.WindowListMessage(windows: [Self.makeWindow()])
        )
        let windowUpdateMessage = MirageWire.ControlMessage(
            type: .windowUpdate,
            payload: Self.emptyWindowUpdatePayload()
        )
        let hostUpdateStatusMessage = try MirageWire.ControlMessage(
            type: .hostSoftwareUpdateStatus,
            content: Self.makeHostSoftwareUpdateStatus()
        )

        await MainActor.run {
            service.setControlUpdatePolicy(.interactiveStreaming)
            service.handleAppListComplete(appListMessage)
            service.handleWindowList(windowListMessage)
            service.handleWindowUpdate(windowUpdateMessage)
            service.handleHostSoftwareUpdateStatus(hostUpdateStatusMessage)

            let firstConsumption = service.consumeDeferredControlRefreshRequirements()
            #expect(firstConsumption.needsAppListRefresh)
            #expect(firstConsumption.needsWindowListRefresh)
            #expect(firstConsumption.needsHostSoftwareUpdateRefresh)

            let secondConsumption = service.consumeDeferredControlRefreshRequirements()
            #expect(!secondConsumption.needsAppListRefresh)
            #expect(!secondConsumption.needsWindowListRefresh)
            #expect(!secondConsumption.needsHostSoftwareUpdateRefresh)
        }
    }

    private static func emptyWindowUpdatePayload() -> Data {
        Data(#"{"added":[],"removed":[],"updated":[]}"#.utf8)
    }

    private static func makeWindow() -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: 101,
            title: "Test Window",
            application: MirageMedia.MirageApplication(
                id: 1,
                bundleIdentifier: "com.example.test",
                name: "Test App"
            ),
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private static func makeHostSoftwareUpdateStatus() -> MirageWire.HostSoftwareUpdateStatusMessage {
        MirageWire.HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: false,
            channel: .release,
            automationMode: .metadataOnly,
            installDisposition: .idle,
            lastBlockReason: nil,
            lastInstallResultCode: nil,
            canCancelUpdate: false,
            downloadExpectedBytes: nil,
            downloadReceivedBytes: 0,
            extractionProgress: nil,
            lastErrorSummary: nil,
            lastErrorDetails: nil,
            currentVersion: "1.0",
            availableVersion: nil,
            availableVersionTitle: nil,
            releaseNotesSummary: nil,
            releaseNotesBody: nil,
            releaseNotesFormat: nil,
            lastCheckedAtMs: nil
        )
    }
}
