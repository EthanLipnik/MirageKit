//
//  MirageWirePayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageInput
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire Payloads")
struct MirageWirePayloadTests {
    @Test("Audio stream payloads round-trip in wire target")
    func audioStreamPayloadsRoundTripInWireTarget() throws {
        let started = MirageWire.AudioStreamStartedMessage(
            streamID: 42,
            codec: .pcm16LE,
            sampleRate: 48_000,
            channelCount: 2
        )
        let startedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .audioStreamStarted, content: started).serialize()
        ).message
        let decodedStarted = try startedEnvelope.decode(MirageWire.AudioStreamStartedMessage.self)
        #expect(decodedStarted == started)

        let stopped = MirageWire.AudioStreamStoppedMessage(streamID: 42, reason: .sourceStopped)
        let stoppedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .audioStreamStopped, content: stopped).serialize()
        ).message
        let decodedStopped = try stoppedEnvelope.decode(MirageWire.AudioStreamStoppedMessage.self)
        #expect(decodedStopped == stopped)
    }

    @Test("Error payloads round-trip in wire target")
    func errorPayloadsRoundTripInWireTarget() throws {
        let message = MirageWire.ErrorMessage(
            code: .appStreamStartupFailed,
            message: "Window could not start.",
            bundleIdentifier: "com.example.WindowedApp"
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .error, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.ErrorMessage.self)
        #expect(decoded.code == .appStreamStartupFailed)
        #expect(decoded.message == "Window could not start.")
        #expect(decoded.bundleIdentifier == "com.example.WindowedApp")

        #expect(MirageWire.ErrorMessage.ErrorCode(MirageCore.MirageRuntimeConditionError.sessionLocked) == .sessionLocked)
        #expect(MirageWire.ErrorMessage.ErrorCode.waitingForHostApproval.runtimeConditionError == .waitingForHostApproval)
        #expect(MirageWire.ErrorMessage.ErrorCode.networkError.runtimeConditionError == nil)
    }

    @Test("Display control payloads round-trip in wire target")
    func displayControlPayloadsRoundTripInWireTarget() throws {
        let transitionID = try #require(UUID(uuidString: "D9993EC3-07B0-4F04-B040-2E9D948086F2"))
        let contractID = try #require(UUID(uuidString: "CE3A2890-390C-44F6-A312-9D5651DD0C7D"))
        let resize = MirageWire.DisplayResolutionChangeMessage(
            streamID: 7,
            displayWidth: 1376,
            displayHeight: 1032,
            transitionID: transitionID,
            requestedDisplayScaleFactor: 2.0,
            requestedStreamScale: 0.875,
            encoderMaxWidth: 2408,
            encoderMaxHeight: 1806,
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "iPad-main-scene",
            desktopGeometryRefreshTargetHz: 45
        )
        let resizeEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .displayResolutionChange, content: resize).serialize()
        ).message
        let decodedResize = try resizeEnvelope.decode(MirageWire.DisplayResolutionChangeMessage.self)
        #expect(decodedResize.transitionID == transitionID)
        #expect(abs(Double((decodedResize.requestedStreamScale ?? 0) - 0.875)) < 0.0001)
        #expect(decodedResize.desktopGeometryContractID == contractID)
        #expect(decodedResize.desktopGeometryRefreshTargetHz == 45)

        let scale = MirageWire.StreamScaleChangeMessage(streamID: 7, streamScale: 0.75)
        let scaleEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamScaleChange, content: scale).serialize()
        ).message
        #expect(try scaleEnvelope.decode(MirageWire.StreamScaleChangeMessage.self).streamScale == 0.75)

        let refresh = MirageWire.StreamRefreshRateChangeMessage(streamID: 7, maxRefreshRate: 60, forceDisplayRefresh: true)
        let refreshEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamRefreshRateChange, content: refresh).serialize()
        ).message
        let decodedRefresh = try refreshEnvelope.decode(MirageWire.StreamRefreshRateChangeMessage.self)
        #expect(decodedRefresh.maxRefreshRate == 60)
        #expect(decodedRefresh.forceDisplayRefresh)
    }

    @Test("Encoder settings payloads round-trip in wire target")
    func encoderSettingsPayloadsRoundTripInWireTarget() throws {
        let request = MirageWire.StreamEncoderSettingsChangeMessage(
            streamID: 9,
            colorDepth: .pro,
            bitrate: 64_000_000,
            bitrateAdaptationCeiling: 128_000_000,
            streamScale: 0.75,
            targetFrameRate: 30
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamEncoderSettingsChange, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamEncoderSettingsChangeMessage.self)
        #expect(decoded.streamID == 9)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.bitrate == 64_000_000)
        #expect(decoded.bitrateAdaptationCeiling == 128_000_000)
        #expect(abs(Double((decoded.streamScale ?? 0) - 0.75)) < 0.0001)
        #expect(decoded.targetFrameRate == 30)
    }

    @Test("Host metadata payloads round-trip in wire target")
    func hostMetadataPayloadsRoundTripInWireTarget() throws {
        let requestID = try #require(UUID(uuidString: "6A7C64FE-5A20-4F76-B100-AB3640E34C6F"))
        let iconRequest = MirageWire.HostHardwareIconRequestMessage(preferredMaxPixelSize: 256)
        let iconRequestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostHardwareIconRequest, content: iconRequest).serialize()
        ).message
        #expect(try iconRequestEnvelope.decode(MirageWire.HostHardwareIconRequestMessage.self).preferredMaxPixelSize == 256)

        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        let icon = MirageWire.HostHardwareIconMessage(
            pngData: iconData,
            iconName: "MacBook Pro",
            hardwareModelIdentifier: "Mac15,6",
            hardwareMachineFamily: "Mac"
        )
        let iconEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostHardwareIcon, content: icon).serialize()
        ).message
        let decodedIcon = try iconEnvelope.decode(MirageWire.HostHardwareIconMessage.self)
        #expect(decodedIcon.pngData == iconData)
        #expect(decodedIcon.hardwareModelIdentifier == "Mac15,6")

        let wallpaperRequest = MirageWire.HostWallpaperRequestMessage(
            requestID: requestID,
            preferredMaxPixelWidth: 1024,
            preferredMaxPixelHeight: 768
        )
        let wallpaperRequestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostWallpaperRequest, content: wallpaperRequest).serialize()
        ).message
        #expect(try wallpaperRequestEnvelope.decode(MirageWire.HostWallpaperRequestMessage.self).requestID == requestID)

        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let wallpaper = MirageWire.HostWallpaperMessage(
            requestID: requestID,
            imageData: imageData,
            pixelWidth: 1024,
            pixelHeight: 768
        )
        let wallpaperEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostWallpaper, content: wallpaper).serialize()
        ).message
        let decodedWallpaper = try wallpaperEnvelope.decode(MirageWire.HostWallpaperMessage.self)
        #expect(decodedWallpaper.imageData == imageData)
        #expect(decodedWallpaper.pixelWidth == 1024)
        #expect(decodedWallpaper.pixelHeight == 768)
    }

    @Test("Support log payloads round-trip in wire target")
    func supportLogPayloadsRoundTripInWireTarget() throws {
        let requestID = try #require(UUID(uuidString: "4B7A6F29-C14C-4DA6-AE46-4E1327DB4D3C"))
        let request = MirageWire.HostSupportLogArchiveRequestMessage(requestID: requestID)
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostSupportLogArchiveRequest, content: request).serialize()
        ).message
        #expect(try requestEnvelope.decode(MirageWire.HostSupportLogArchiveRequestMessage.self).requestID == requestID)

        let response = MirageWire.HostSupportLogArchiveMessage(
            requestID: requestID,
            fileName: "MirageHostSupport.zip",
            errorMessage: nil
        )
        let responseEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostSupportLogArchive, content: response).serialize()
        ).message
        let decoded = try responseEnvelope.decode(MirageWire.HostSupportLogArchiveMessage.self)
        #expect(decoded.fileName == "MirageHostSupport.zip")
        #expect(decoded.errorMessage == nil)
    }

    @Test("Host application control payloads round-trip in wire target")
    func hostApplicationControlPayloadsRoundTripInWireTarget() throws {
        let result = MirageWire.HostApplicationRestartResultMessage(
            accepted: true,
            message: "Restarting Mirage Host."
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostApplicationRestartResult, content: result).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.HostApplicationRestartResultMessage.self)
        #expect(decoded.accepted)
        #expect(decoded.message == "Restarting Mirage Host.")
    }

    @Test("Software update payloads round-trip in wire target")
    func softwareUpdatePayloadsRoundTripInWireTarget() throws {
        let request = MirageWire.HostSoftwareUpdateStatusRequestMessage(forceRefresh: true)
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostSoftwareUpdateStatusRequest, content: request).serialize()
        ).message
        #expect(try requestEnvelope.decode(MirageWire.HostSoftwareUpdateStatusRequestMessage.self).forceRefresh)

        let status = softwareUpdateStatus()
        let statusEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostSoftwareUpdateStatus, content: status).serialize()
        ).message
        let decodedStatus = try statusEnvelope.decode(MirageWire.HostSoftwareUpdateStatusMessage.self)
        #expect(decodedStatus.channel == .nightly)
        #expect(decodedStatus.automationMode == .autoDownload)
        #expect(decodedStatus.installDisposition == .installing)
        #expect(decodedStatus.downloadExpectedBytes == 1000)
        #expect(decodedStatus.extractionProgress == 0.25)
        #expect(decodedStatus.releaseNotesFormat == .html)

        let installResult = MirageWire.HostSoftwareUpdateInstallResultMessage(
            message: "Denied",
            resultCode: .denied,
            blockReason: .policyDenied,
            remediationHint: "Try again later.",
            status: status
        )
        let installResultEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .hostSoftwareUpdateInstallResult, content: installResult).serialize()
        ).message
        let decodedInstallResult = try installResultEnvelope.decode(MirageWire.HostSoftwareUpdateInstallResultMessage.self)
        #expect(decodedInstallResult.message == "Denied")
        #expect(decodedInstallResult.resultCode == .denied)
        #expect(decodedInstallResult.blockReason == .policyDenied)
        #expect(decodedInstallResult.status.currentVersion == "1.2.0")
    }

    @Test("Connection payloads round-trip in wire target")
    func connectionPayloadsRoundTripInWireTarget() throws {
        let hostID = try #require(UUID(uuidString: "D3D0D7F9-459D-4F06-A786-43F3956315AA"))
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageWireProtocol.currentControlVersion),
            clientRequiresMediaEncryption: true,
            requestTakeoverIfBusy: true
        )
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .sessionBootstrapRequest, content: request).serialize()
        ).message
        let decodedRequest = try requestEnvelope.decode(MirageWire.MirageSessionBootstrapRequest.self)
        #expect(decodedRequest.clientRequiresMediaEncryption)
        #expect(decodedRequest.requestTakeoverIfBusy)

        let response = MirageWire.MirageSessionBootstrapResponse(
            accepted: false,
            hostID: hostID,
            hostName: "Studio Mac",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data([0xAA, 0xBB]),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 260604,
            protocolMismatchClientVersion: 250101,
            authorizationFailureReason: .remoteAccessDisabled
        )
        let responseEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .sessionBootstrapResponse, content: response).serialize()
        ).message
        let decodedResponse = try responseEnvelope.decode(MirageWire.MirageSessionBootstrapResponse.self)
        #expect(decodedResponse.rejectionReason == .protocolVersionMismatch)
        #expect(decodedResponse.authorizationFailureReason == .remoteAccessDisabled)
        #expect(decodedResponse.protocolMismatchClientVersion == 250101)

        let disconnect = MirageWire.DisconnectMessage(reason: .hostUpdateInProgress)
        let disconnectEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .disconnect, content: disconnect).serialize()
        ).message
        #expect(try disconnectEnvelope.decode(MirageWire.DisconnectMessage.self).reason == .hostUpdateInProgress)

        let refresh = MirageWire.TransportRefreshRequestMessage(streamID: 7, reason: "network-path-changed")
        let refreshEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .transportRefreshRequest, content: refresh).serialize()
        ).message
        let decodedRefresh = try refreshEnvelope.decode(MirageWire.TransportRefreshRequestMessage.self)
        #expect(decodedRefresh.streamID == 7)
        #expect(decodedRefresh.reason == "network-path-changed")

        let leaseID = try #require(UUID(uuidString: "A06C2B3C-4300-4D22-BED6-E37007180B61"))
        let lease = MirageWire.ClientBackgroundLeaseMessage(
            leaseID: leaseID,
            durationSeconds: 30,
            mode: .suspendedUntilForeground
        )
        let leaseData = try JSONEncoder().encode(lease)
        let decodedLease = try JSONDecoder().decode(MirageWire.ClientBackgroundLeaseMessage.self, from: leaseData)
        #expect(decodedLease == lease)
    }

    @Test("Priority input envelope round-trips in wire target")
    func priorityInputEnvelopeRoundTripsInWireTarget() throws {
        let envelope = MirageWire.MiragePriorityInputEnvelope(
            kind: .input,
            eventID: 42,
            streamID: 7,
            deliveryClass: .protected,
            sentAtUptime: 123.456,
            inputPayload: Data([0x00, 0xFE, 0x7A])
        )

        let decoded = try MirageWire.MiragePriorityInputEnvelope.deserialize(envelope.serialize())

        #expect(decoded == envelope)
        #expect(try decoded.inputControlMessage().type == .inputEvent)
        #expect(try decoded.inputControlMessage().payload == Data([0x00, 0xFE, 0x7A]))
    }

    @Test("Priority input fallback control type parses in wire target")
    func priorityInputFallbackControlTypeParsesInWireTarget() throws {
        let envelope = MirageWire.MiragePriorityInputEnvelope(
            kind: .ack,
            eventID: 9,
            streamID: 0,
            deliveryClass: .realtime,
            sentAtUptime: 1
        )
        let controlMessage = MirageWire.ControlMessage(
            type: .priorityInputEvent,
            payload: try envelope.serialize()
        )

        let parsed = try parsedControlMessage(from: controlMessage.serialize())
        #expect(parsed.bytesConsumed == controlMessage.serialize().count)
        #expect(parsed.message.type == .priorityInputEvent)
        #expect(try MirageWire.MiragePriorityInputEnvelope.deserialize(parsed.message.payload) == envelope)
    }

    @Test("Input event payloads round-trip in wire target")
    func inputEventPayloadsRoundTripInWireTarget() throws {
        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: 0x24,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            modifiers: [.command],
            isRepeat: true,
            timestamp: 123.456
        )
        let message = MirageWire.InputEventMessage(streamID: 42, event: .keyDown(keyEvent))
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .inputEvent, payload: try message.serializePayload()).serialize()
        ).message
        let decoded = try MirageWire.InputEventMessage.deserializePayload(envelope.payload)

        #expect(envelope.type == .inputEvent)
        #expect(decoded.streamID == 42)
        guard case let .keyDown(decodedKeyEvent) = decoded.event else {
            Issue.record("Expected keyDown input event.")
            return
        }
        #expect(decodedKeyEvent == keyEvent)
    }

    @Test("Shared clipboard payloads round-trip in wire target")
    func sharedClipboardPayloadsRoundTripInWireTarget() throws {
        let status = MirageWire.SharedClipboardStatusMessage(enabled: true)
        let statusEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .sharedClipboardStatus, content: status).serialize()
        ).message
        #expect(try statusEnvelope.decode(MirageWire.SharedClipboardStatusMessage.self).enabled)

        let changeID = try #require(UUID(uuidString: "A18EF9AE-2C4E-4D1D-8E4B-6320817413A0"))
        let representation = MirageWire.SharedClipboardRepresentation(
            kind: .file,
            contentType: "public.data",
            filename: "Support.txt",
            byteCount: 3
        )
        let update = MirageWire.SharedClipboardUpdateMessage(
            changeID: changeID,
            logicalVersion: 42,
            sentAtMs: 1_234_567,
            representation: representation,
            encryptedPayload: Data([0x01, 0x02, 0x03]),
            chunkIndex: 2,
            chunkCount: 5
        )
        let updateEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .sharedClipboardUpdate, content: update).serialize()
        ).message
        let decodedUpdate = try updateEnvelope.decode(MirageWire.SharedClipboardUpdateMessage.self)
        #expect(decodedUpdate.representation == representation)
        #expect(decodedUpdate.encryptedPayload == Data([0x01, 0x02, 0x03]))
        #expect(decodedUpdate.chunkIndex == 2)
        #expect(decodedUpdate.chunkCount == 5)
        #expect(decodedUpdate.orderingToken == MirageWire.MirageSharedClipboardOrderingToken(
            logicalVersion: 42,
            changeID: changeID
        ))
    }

    @Test("Keyframe recovery payloads round-trip in wire target")
    func keyframeRecoveryPayloadsRoundTripInWireTarget() throws {
        let request = MirageWire.KeyframeRequestMessage(streamID: 17, recoveryCause: .decodeError)
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .keyframeRequest, content: request).serialize()
        ).message
        let decodedRequest = try requestEnvelope.decode(MirageWire.KeyframeRequestMessage.self)
        #expect(decodedRequest.streamID == 17)
        #expect(decodedRequest.recoveryCause == .decodeError)

        let legacyRequestPayload = Data(#"{"streamID":17}"#.utf8)
        let legacyRequest = try JSONDecoder().decode(MirageWire.KeyframeRequestMessage.self, from: legacyRequestPayload)
        #expect(legacyRequest.recoveryCause == .none)

        let ack = MirageWire.KeyframeRecoveryAckMessage(
            streamID: 17,
            deadlineMilliseconds: -25,
            accepted: false,
            state: .cooldown
        )
        let ackEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .keyframeRecoveryAck, content: ack).serialize()
        ).message
        let decodedAck = try ackEnvelope.decode(MirageWire.KeyframeRecoveryAckMessage.self)
        #expect(decodedAck.streamID == 17)
        #expect(decodedAck.deadlineMilliseconds == 0)
        #expect(decodedAck.accepted == false)
        #expect(decodedAck.state == .cooldown)

        let legacyAckPayload = Data(#"{"streamID":17,"deadlineMilliseconds":10,"accepted":false}"#.utf8)
        let legacyAck = try JSONDecoder().decode(MirageWire.KeyframeRecoveryAckMessage.self, from: legacyAckPayload)
        #expect(legacyAck.state == .cooldown)
    }

    @Test("App window close-alert payloads round-trip in wire target")
    func appWindowCloseAlertPayloadsRoundTripInWireTarget() throws {
        let alert = MirageWire.AppWindowCloseBlockedAlertMessage(
            bundleIdentifier: "com.apple.TextEdit",
            sourceWindowID: 901,
            presentingStreamID: 41,
            alertToken: "token-123",
            title: "Save changes?",
            message: "Do you want to save the changes made to this document?",
            actions: [
                .init(id: "action-0", title: "Cancel"),
                .init(id: "action-1", title: "Don't Save", isDestructive: true),
                .init(id: "action-2", title: "Save"),
            ]
        )
        let alertEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowCloseBlockedAlert, content: alert).serialize()
        ).message
        let decodedAlert = try alertEnvelope.decode(MirageWire.AppWindowCloseBlockedAlertMessage.self)
        #expect(decodedAlert.bundleIdentifier == "com.apple.TextEdit")
        #expect(decodedAlert.sourceWindowID == 901)
        #expect(decodedAlert.presentingStreamID == 41)
        #expect(decodedAlert.actions[1].isDestructive)

        let request = MirageWire.AppWindowCloseAlertActionRequestMessage(
            alertToken: "token-abc",
            actionID: "action-2",
            presentingStreamID: 73
        )
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowCloseAlertActionRequest, content: request).serialize()
        ).message
        let decodedRequest = try requestEnvelope.decode(MirageWire.AppWindowCloseAlertActionRequestMessage.self)
        #expect(decodedRequest.alertToken == "token-abc")
        #expect(decodedRequest.actionID == "action-2")
        #expect(decodedRequest.presentingStreamID == 73)

        let result = MirageWire.AppWindowCloseAlertActionResultMessage(
            alertToken: "token-result",
            actionID: "action-1",
            success: false,
            reason: "Presenting stream mismatch"
        )
        let resultEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowCloseAlertActionResult, content: result).serialize()
        ).message
        let decodedResult = try resultEnvelope.decode(MirageWire.AppWindowCloseAlertActionResultMessage.self)
        #expect(decodedResult.alertToken == "token-result")
        #expect(decodedResult.actionID == "action-1")
        #expect(decodedResult.success == false)
        #expect(decodedResult.reason == "Presenting stream mismatch")
    }
}
