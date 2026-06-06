//
//  MirageKitSoftwareUpdateSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
@testable import MirageKit
import Testing
import MirageWire

@Suite("MirageKit Software Update Serialization")
struct MirageKitSoftwareUpdateSerializationTests {
    @Test("Host software update control message serialization")
    func hostSoftwareUpdateControlMessageSerialization() throws {
        let statusRequest = MirageWire.HostSoftwareUpdateStatusRequestMessage(forceRefresh: true)
        let requestEnvelope = try MirageWire.ControlMessage(type: .hostSoftwareUpdateStatusRequest, content: statusRequest)
        let (decodedRequestEnvelope, _) = try requireParsedControlMessage(from: requestEnvelope.serialize())
        let decodedStatusRequest = try decodedRequestEnvelope.decode(MirageWire.HostSoftwareUpdateStatusRequestMessage.self)
        #expect(decodedStatusRequest.forceRefresh == true)

        let status = MirageWire.HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: true,
            channel: .nightly,
            automationMode: .autoDownload,
            installDisposition: .installing,
            lastBlockReason: nil,
            lastInstallResultCode: .started,
            canCancelUpdate: true,
            downloadExpectedBytes: 1000,
            downloadReceivedBytes: 250,
            extractionProgress: 0.25,
            lastErrorSummary: nil,
            lastErrorDetails: nil,
            currentVersion: "1.2.0",
            availableVersion: "1.3.0",
            availableVersionTitle: "Mirage 1.3",
            releaseNotesSummary: "Maintenance release",
            releaseNotesBody: "<ul><li>Improved reliability</li></ul>",
            releaseNotesFormat: .html,
            lastCheckedAtMs: 1_700_000_000_000
        )
        let statusEnvelope = try MirageWire.ControlMessage(type: .hostSoftwareUpdateStatus, content: status)
        let (decodedStatusEnvelope, _) = try requireParsedControlMessage(from: statusEnvelope.serialize())
        let decodedStatus = try decodedStatusEnvelope.decode(MirageWire.HostSoftwareUpdateStatusMessage.self)
        #expect(decodedStatus.channel == .nightly)
        #expect(decodedStatus.availableVersion == "1.3.0")
        #expect(decodedStatus.isInstallInProgress == true)
        #expect(decodedStatus.automationMode == .autoDownload)
        #expect(decodedStatus.installDisposition == .installing)
        #expect(decodedStatus.canCancelUpdate == true)
        #expect(decodedStatus.downloadExpectedBytes == 1000)
        #expect(decodedStatus.downloadReceivedBytes == 250)
        #expect(decodedStatus.extractionProgress == 0.25)
        #expect(decodedStatus.releaseNotesFormat == .html)

        let installRequestEnvelope = MirageWire.ControlMessage(type: .hostSoftwareUpdateInstallRequest)
        let (decodedInstallRequestEnvelope, _) = try requireParsedControlMessage(from: installRequestEnvelope.serialize())
        #expect(decodedInstallRequestEnvelope.payload.isEmpty)

        let installResult = MirageWire.HostSoftwareUpdateInstallResultMessage(
            message: "Denied",
            resultCode: .denied,
            blockReason: .policyDenied,
            remediationHint: nil,
            status: status
        )
        let installResultEnvelope = try MirageWire.ControlMessage(type: .hostSoftwareUpdateInstallResult, content: installResult)
        let (decodedInstallResultEnvelope, _) = try requireParsedControlMessage(from: installResultEnvelope.serialize())
        let decodedInstallResult = try decodedInstallResultEnvelope.decode(MirageWire.HostSoftwareUpdateInstallResultMessage.self)
        #expect(decodedInstallResult.status.currentVersion == "1.2.0")
        #expect(decodedInstallResult.message == "Denied")
        #expect(decodedInstallResult.resultCode == .denied)
        #expect(decodedInstallResult.blockReason == .policyDenied)

        let restartRequestEnvelope = MirageWire.ControlMessage(type: .hostApplicationRestartRequest)
        let (decodedRestartRequestEnvelope, _) = try requireParsedControlMessage(from: restartRequestEnvelope.serialize())
        #expect(decodedRestartRequestEnvelope.payload.isEmpty)

        let restartResult = MirageWire.HostApplicationRestartResultMessage(
            accepted: true,
            message: "Restarting Mirage Host."
        )
        let restartResultEnvelope = try MirageWire.ControlMessage(type: .hostApplicationRestartResult, content: restartResult)
        let (decodedRestartResultEnvelope, _) = try requireParsedControlMessage(from: restartResultEnvelope.serialize())
        let decodedRestartResult = try decodedRestartResultEnvelope.decode(MirageWire.HostApplicationRestartResultMessage.self)
        #expect(decodedRestartResult.accepted == true)
        #expect(decodedRestartResult.message == "Restarting Mirage Host.")
    }

}
