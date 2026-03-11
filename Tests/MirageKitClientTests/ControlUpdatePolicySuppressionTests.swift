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

@Suite("Control Update Policy Suppression")
struct ControlUpdatePolicySuppressionTests {
    @Test("Interactive policy drop-set matches non-essential control messages")
    func interactivePolicyDropSet() {
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.appList))
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.appIconUpdate))
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.appIconStreamComplete))
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.windowList))
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.windowUpdate))
        #expect(MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.hostSoftwareUpdateStatus))
    }

    @Test("Interactive policy never drops essential stream/control messages")
    func interactivePolicyEssentialMessagesRemainEnabled() {
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.helloResponse))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.streamStarted))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.streamStopped))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.desktopStreamStarted))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.audioStreamStarted))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.sharedClipboardStatus))
        #expect(!MirageClientService.shouldDropNonEssentialControlMessageWhileInteractive(.sharedClipboardUpdate))
    }

    @Test("Deferred refresh requirements are tracked and consumed once")
    func deferredRefreshRequirementsConsumeOnce() async throws {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let appListMessage = try ControlMessage(
            type: .appList,
            content: AppListMessage(requestID: UUID(), apps: [])
        )
        let appIconUpdateMessage = try ControlMessage(
            type: .appIconUpdate,
            content: AppIconUpdateMessage(
                requestID: UUID(),
                bundleIdentifier: "com.example.test",
                iconData: Data([0x01]),
                iconSignature: "deadbeef"
            )
        )
        let windowListMessage = try ControlMessage(
            type: .windowList,
            content: WindowListMessage(windows: [Self.makeWindow()])
        )
        let windowUpdateMessage = try ControlMessage(
            type: .windowUpdate,
            content: WindowUpdateMessage(added: [], removed: [], updated: [])
        )
        let hostUpdateStatusMessage = try ControlMessage(
            type: .hostSoftwareUpdateStatus,
            content: Self.makeHostSoftwareUpdateStatus()
        )

        await MainActor.run {
            service.setControlUpdatePolicy(.interactiveStreaming)
            service.handleAppList(appListMessage)
            service.handleAppIconUpdate(appIconUpdateMessage)
            service.handleWindowList(windowListMessage)
            service.handleWindowUpdate(windowUpdateMessage)
            service.handleHostSoftwareUpdateStatus(hostUpdateStatusMessage)

            let firstConsumption = service.consumeDeferredControlRefreshRequirements()
            #expect(firstConsumption.needsAppListRefresh)
            #expect(firstConsumption.needsWindowListRefresh)
            #expect(firstConsumption.needsHostSoftwareUpdateRefresh)

            let secondConsumption = service.consumeDeferredControlRefreshRequirements()
            #expect(!secondConsumption.hasAny)
        }
    }

    private static func makeWindow() -> MirageWindow {
        MirageWindow(
            id: 101,
            title: "Test Window",
            application: MirageApplication(
                id: 1,
                bundleIdentifier: "com.example.test",
                name: "Test App"
            ),
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private static func makeHostSoftwareUpdateStatus() -> HostSoftwareUpdateStatusMessage {
        HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: false,
            channel: .release,
            automationMode: .metadataOnly,
            installDisposition: .idle,
            lastBlockReason: nil,
            lastInstallResultCode: nil,
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
