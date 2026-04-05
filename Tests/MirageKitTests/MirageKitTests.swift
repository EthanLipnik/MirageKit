//
//  MirageKitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import CoreVideo
@testable import MirageKit
import Testing

@Suite("MirageKit Tests")
struct MirageKitTests {
    @Test("Protocol header serialization")
    func frameHeaderSerialization() {
        let header = FrameHeader(
            flags: [.keyframe, .endOfFrame],
            streamID: 1,
            sequenceNumber: 100,
            timestamp: 123_456_789,
            frameNumber: 50,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: 1024,
            frameByteCount: 1024,
            checksum: 0xDEAD_BEEF
        )

        let data = header.serialize()
        #expect(data.count == mirageHeaderSize)

        let deserialized = FrameHeader.deserialize(from: data)
        #expect(deserialized != nil)
        #expect(deserialized?.streamID == 1)
        #expect(deserialized?.sequenceNumber == 100)
        #expect(deserialized?.frameNumber == 50)
        #expect(deserialized?.flags.contains(FrameFlags.keyframe) == true)
    }

    @Test("CRC32 calculation")
    func cRC32() {
        let data = Data("Hello, World!".utf8)
        let crc = CRC32.calculate(data)
        #expect(crc != 0)

        // Same data should produce same CRC
        let crc2 = CRC32.calculate(data)
        #expect(crc == crc2)

        // Different data should produce different CRC
        let data2 = Data("Hello, MirageKit!".utf8)
        let crc3 = CRC32.calculate(data2)
        #expect(crc != crc3)
    }

    @Test("Control message serialization")
    func controlMessageSerialization() throws {
        let bootstrap = MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.protocolVersion),
            requestedFeatures: mirageSupportedFeatures
        )

        let message = try ControlMessage(type: .sessionBootstrapRequest, content: bootstrap)
        let data = message.serialize()

        let (deserialized, consumed) = try requireParsedControlMessage(from: data)
        #expect(consumed == data.count)
        #expect(deserialized.type == .sessionBootstrapRequest)

        let decodedBootstrap = try deserialized.decode(MirageSessionBootstrapRequest.self)
        #expect(decodedBootstrap.protocolVersion == Int(MirageKit.protocolVersion))
        #expect(decodedBootstrap.requestedFeatures == mirageSupportedFeatures)
    }

    @Test("Control parser rejects unknown control type")
    func controlParserRejectsUnknownControlType() {
        var data = Data([0x06])
        withUnsafeBytes(of: UInt32(0).littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case .invalidFrame:
            break
        default:
            Issue.record("Expected invalidFrame for unknown control message type.")
        }
    }

    @Test("Close-blocked app window alert control type is recognized")
    func closeBlockedAppWindowAlertControlTypeIsRecognized() {
        var data = Data([ControlMessageType.appWindowCloseBlockedAlert.rawValue])
        withUnsafeBytes(of: UInt32(0).littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case let .success(message, consumed):
            #expect(consumed == data.count)
            #expect(message.type == .appWindowCloseBlockedAlert)
        default:
            Issue.record("Expected close-blocked alert control type to parse successfully.")
        }
    }

    @Test("Quality-test cancel control type is recognized")
    func qualityTestCancelControlTypeIsRecognized() throws {
        let payload = QualityTestCancelMessage(testID: UUID())
        let envelope = try ControlMessage(type: .qualityTestCancel, content: payload)

        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        #expect(decodedEnvelope.type == .qualityTestCancel)

        let decodedPayload = try decodedEnvelope.decode(QualityTestCancelMessage.self)
        #expect(decodedPayload.testID == payload.testID)
    }

    @Test("Control parser returns needMoreData for truncated payload")
    func controlParserReturnsNeedMoreDataForTruncatedPayload() {
        var data = Data([ControlMessageType.sessionBootstrapRequest.rawValue])
        withUnsafeBytes(of: UInt32(8).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x01, 0x02, 0x03])

        switch ControlMessage.deserialize(from: data) {
        case .needMoreData:
            break
        default:
            Issue.record("Expected needMoreData for truncated payload.")
        }
    }

    @Test("Control parser rejects oversized app list payload")
    func controlParserRejectsOversizedAppListPayload() {
        var data = Data([ControlMessageType.appList.rawValue])
        let oversizedLength = UInt32(LoomMessageLimits.maxLargeMetadataPayloadBytes + 1)
        withUnsafeBytes(of: oversizedLength.littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case .invalidFrame:
            break
        default:
            Issue.record("Expected invalidFrame for oversized appList payload.")
        }
    }

    @Test("Control parser rejects oversized app icon payload")
    func controlParserRejectsOversizedAppIconPayload() {
        var data = Data([ControlMessageType.appIconUpdate.rawValue])
        let oversizedLength = UInt32(LoomMessageLimits.maxInlineAssetPayloadBytes + 1)
        withUnsafeBytes(of: oversizedLength.littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case .invalidFrame:
            break
        default:
            Issue.record("Expected invalidFrame for oversized appIconUpdate payload.")
        }
    }

    @Test("Control parser rejects oversized host wallpaper payload")
    func controlParserRejectsOversizedHostWallpaperPayload() {
        var data = Data([ControlMessageType.hostWallpaper.rawValue])
        let oversizedLength = UInt32(LoomMessageLimits.maxInlineAssetPayloadBytes + 1)
        withUnsafeBytes(of: oversizedLength.littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case .invalidFrame:
            break
        default:
            Issue.record("Expected invalidFrame for oversized hostWallpaper payload.")
        }
    }

    @Test("Host wallpaper message serialization")
    func hostWallpaperMessageSerialization() throws {
        let wallpaper = HostWallpaperMessage(
            requestID: UUID(),
            fileName: "wallpaper.jpg",
            pixelWidth: 1_280,
            pixelHeight: 720,
            bytesPerPixelEstimate: 4
        )

        let envelope = try ControlMessage(type: .hostWallpaper, content: wallpaper)
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        #expect(decodedEnvelope.type == .hostWallpaper)

        let decoded = try decodedEnvelope.decode(HostWallpaperMessage.self)
        #expect(decoded.requestID == wallpaper.requestID)
        #expect(decoded.fileName == "wallpaper.jpg")
        #expect(decoded.pixelWidth == 1_280)
        #expect(decoded.pixelHeight == 720)
        #expect(decoded.bytesPerPixelEstimate == 4)
    }

    @Test("Bootstrap request optional mismatch update flag serialization")
    func bootstrapRequestOptionalMismatchUpdateFlagSerialization() throws {
        let bootstrap = MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.protocolVersion),
            requestedFeatures: mirageSupportedFeatures,
            requestHostUpdateOnProtocolMismatch: true
        )

        let message = try ControlMessage(type: .sessionBootstrapRequest, content: bootstrap)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: message.serialize())
        let decodedBootstrap = try decodedEnvelope.decode(MirageSessionBootstrapRequest.self)
        #expect(decodedBootstrap.requestHostUpdateOnProtocolMismatch == true)
    }

    @Test("Bootstrap response mismatch metadata serialization")
    func bootstrapResponseMismatchMetadataSerialization() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            selectedFeatures: [],
            mediaEncryptionEnabled: false,
            udpRegistrationToken: Data(),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 1,
            protocolMismatchClientVersion: 2,
            protocolMismatchUpdateTriggerAccepted: true,
            protocolMismatchUpdateTriggerMessage: "Update accepted"
        )

        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)
        #expect(decoded.rejectionReason == .protocolVersionMismatch)
        #expect(decoded.protocolMismatchHostVersion == 1)
        #expect(decoded.protocolMismatchClientVersion == 2)
        #expect(decoded.protocolMismatchUpdateTriggerAccepted == true)
        #expect(decoded.protocolMismatchUpdateTriggerMessage == "Update accepted")
    }

    @Test("Accepted bootstrap response off-LAN access metadata serialization")
    func bootstrapResponseRemoteAccessMetadataSerialization() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: true,
            hostID: UUID(),
            hostName: "Host",
            selectedFeatures: mirageSupportedFeatures,
            mediaEncryptionEnabled: true,
            udpRegistrationToken: Data(
                repeating: 0xAB,
                count: MirageMediaSecurity.registrationTokenLength
            ),
            remoteAccessAllowed: true
        )

        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)

        #expect(decoded.accepted == true)
        #expect(decoded.remoteAccessAllowed == true)
    }

    @Test("Audio control message serialization")
    func audioControlMessageSerialization() throws {
        let started = AudioStreamStartedMessage(
            streamID: 42,
            codec: .aacLC,
            sampleRate: 48_000,
            channelCount: 2
        )
        let startedEnvelope = try ControlMessage(type: .audioStreamStarted, content: started)
        let (decodedStartedEnvelope, _) = try requireParsedControlMessage(from: startedEnvelope.serialize())
        #expect(decodedStartedEnvelope.type == .audioStreamStarted)
        let decodedStarted = try decodedStartedEnvelope.decode(AudioStreamStartedMessage.self)
        #expect(decodedStarted == started)

        let stopped = AudioStreamStoppedMessage(streamID: 42, reason: .sourceStopped)
        let stoppedEnvelope = try ControlMessage(type: .audioStreamStopped, content: stopped)
        let (decodedStoppedEnvelope, _) = try requireParsedControlMessage(from: stoppedEnvelope.serialize())
        #expect(decodedStoppedEnvelope.type == .audioStreamStopped)
        let decodedStopped = try decodedStoppedEnvelope.decode(AudioStreamStoppedMessage.self)
        #expect(decodedStopped == stopped)
    }

    @Test("Transport refresh request message serialization")
    func transportRefreshRequestMessageSerialization() throws {
        let refresh = TransportRefreshRequestMessage(
            streamID: 7,
            reason: "send-error-burst",
            requestedAtNs: 12_345
        )
        let envelope = try ControlMessage(type: .transportRefreshRequest, content: refresh)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(decodedEnvelope.type == .transportRefreshRequest)
        let decoded = try decodedEnvelope.decode(TransportRefreshRequestMessage.self)
        #expect(decoded.streamID == 7)
        #expect(decoded.reason == "send-error-burst")
        #expect(decoded.requestedAtNs == 12_345)
    }

    @Test("Select app message includes max visible slot count")
    func selectAppMessageMaxVisibleSlotsSerialization() throws {
        let request = SelectAppMessage(
            bundleIdentifier: "com.apple.mail",
            maxRefreshRate: 120,
            maxConcurrentVisibleWindows: 8
        )
        let envelope = try ControlMessage(type: .selectApp, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(SelectAppMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.mail")
        #expect(decoded.maxConcurrentVisibleWindows == 8)
    }

    @Test("App list request supports icon reset and priority ordering")
    func appListRequestSerialization() throws {
        let request = AppListRequestMessage(
            forceRefresh: true,
            forceIconReset: true,
            priorityBundleIdentifiers: [
                "com.apple.mail",
                "com.apple.safari",
            ],
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        )

        let envelope = try ControlMessage(type: .appListRequest, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppListRequestMessage.self)

        #expect(decoded.forceRefresh)
        #expect(decoded.forceIconReset)
        #expect(decoded.priorityBundleIdentifiers == ["com.apple.mail", "com.apple.safari"])
        #expect(decoded.requestID.uuidString.lowercased() == "00000000-0000-0000-0000-000000000123")
    }

    @Test("App list request decoding defaults missing optional protocol fields")
    func appListRequestDecodingDefaultsForMissingFields() throws {
        let legacyPayload = Data(#"{"forceRefresh":true}"#.utf8)
        let envelope = ControlMessage(type: .appListRequest, payload: legacyPayload)
        let decoded = try envelope.decode(AppListRequestMessage.self)

        #expect(decoded.forceRefresh)
        #expect(decoded.forceIconReset == false)
        #expect(decoded.priorityBundleIdentifiers.isEmpty)
        #expect(decoded.requestID.uuidString.count == 36)
    }

    @Test("App list request decoding tolerates invalid new-field types")
    func appListRequestDecodingToleratesTypeMismatch() throws {
        let payload = Data(
            #"{"forceRefresh":true,"forceIconReset":"true","priorityBundleIdentifiers":"com.apple.mail","requestID":"00000000-0000-0000-0000-000000000abc"}"#
                .utf8
        )
        let envelope = ControlMessage(type: .appListRequest, payload: payload)
        let decoded = try envelope.decode(AppListRequestMessage.self)

        #expect(decoded.forceRefresh)
        #expect(decoded.forceIconReset == false)
        #expect(decoded.priorityBundleIdentifiers.isEmpty)
        #expect(decoded.requestID.uuidString.lowercased() == "00000000-0000-0000-0000-000000000abc")
    }

    @Test("Metadata app list and icon stream messages serialize")
    func appListAndIconStreamSerialization() throws {
        let metadataApps = [
            MirageInstalledApp(
                bundleIdentifier: "com.apple.mail",
                name: "Mail",
                path: "/Applications/Mail.app",
                iconData: nil,
                version: "1.0",
                isRunning: true,
                isBeingStreamed: false
            ),
        ]
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let appList = AppListMessage(requestID: requestID, apps: metadataApps)
        let appListEnvelope = try ControlMessage(type: .appList, content: appList)
        let (decodedAppListEnvelope, _) = try requireParsedControlMessage(from: appListEnvelope.serialize())
        let decodedAppList = try decodedAppListEnvelope.decode(AppListMessage.self)
        #expect(decodedAppList.requestID == requestID)
        #expect(decodedAppList.apps.count == 1)
        #expect(decodedAppList.apps[0].iconData == nil)

        let iconUpdate = AppIconUpdateMessage(
            requestID: requestID,
            bundleIdentifier: "com.apple.mail",
            iconData: Data([0x01, 0x02, 0x03]),
            iconSignature: "abc123"
        )
        let iconEnvelope = try ControlMessage(type: .appIconUpdate, content: iconUpdate)
        let (decodedIconEnvelope, _) = try requireParsedControlMessage(from: iconEnvelope.serialize())
        let decodedIcon = try decodedIconEnvelope.decode(AppIconUpdateMessage.self)
        #expect(decodedIcon.requestID == requestID)
        #expect(decodedIcon.bundleIdentifier == "com.apple.mail")
        #expect(decodedIcon.iconData == Data([0x01, 0x02, 0x03]))
        #expect(decodedIcon.iconSignature == "abc123")

        let completion = AppIconStreamCompleteMessage(
            requestID: requestID,
            sentIconCount: 12,
            skippedBundleIdentifiers: ["com.apple.finder"]
        )
        let completionEnvelope = try ControlMessage(type: .appIconStreamComplete, content: completion)
        let (decodedCompletionEnvelope, _) = try requireParsedControlMessage(from: completionEnvelope.serialize())
        let decodedCompletion = try decodedCompletionEnvelope.decode(AppIconStreamCompleteMessage.self)
        #expect(decodedCompletion.requestID == requestID)
        #expect(decodedCompletion.sentIconCount == 12)
        #expect(decodedCompletion.skippedBundleIdentifiers == ["com.apple.finder"])
    }

    @Test("App window inventory and swap messages serialize")
    func appWindowInventoryAndSwapSerialization() throws {
        let metadata = AppWindowInventoryMessage.WindowMetadata(
            windowID: 9001,
            title: "Inbox",
            width: 1440,
            height: 900,
            isResizable: true
        )
        let inventory = AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.mail",
            maxVisibleSlots: 8,
            slots: [
                .init(slotIndex: 0, streamID: 41, window: metadata),
            ],
            hiddenWindows: [
                .init(
                    windowID: 9002,
                    title: "Draft",
                    width: 1280,
                    height: 860,
                    isResizable: true
                ),
            ]
        )
        let inventoryEnvelope = try ControlMessage(type: .appWindowInventory, content: inventory)
        let (decodedInventoryEnvelope, _) = try requireParsedControlMessage(from: inventoryEnvelope.serialize())
        let decodedInventory = try decodedInventoryEnvelope.decode(AppWindowInventoryMessage.self)
        #expect(decodedInventory.bundleIdentifier == "com.apple.mail")
        #expect(decodedInventory.maxVisibleSlots == 8)
        #expect(decodedInventory.slots.count == 1)
        #expect(decodedInventory.hiddenWindows.count == 1)

        let swapRequest = AppWindowSwapRequestMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 41,
            targetWindowID: 9002
        )
        let requestEnvelope = try ControlMessage(type: .appWindowSwapRequest, content: swapRequest)
        let (decodedRequestEnvelope, _) = try requireParsedControlMessage(from: requestEnvelope.serialize())
        let decodedSwapRequest = try decodedRequestEnvelope.decode(AppWindowSwapRequestMessage.self)
        #expect(decodedSwapRequest.targetSlotStreamID == 41)
        #expect(decodedSwapRequest.targetWindowID == 9002)

        let swapResult = AppWindowSwapResultMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 41,
            windowID: 9002,
            success: true,
            reason: nil
        )
        let resultEnvelope = try ControlMessage(type: .appWindowSwapResult, content: swapResult)
        let (decodedResultEnvelope, _) = try requireParsedControlMessage(from: resultEnvelope.serialize())
        let decodedSwapResult = try decodedResultEnvelope.decode(AppWindowSwapResultMessage.self)
        #expect(decodedSwapResult.success == true)
        #expect(decodedSwapResult.targetSlotStreamID == 41)
        #expect(decodedSwapResult.windowID == 9002)
    }

    @Test("Host software update control message serialization")
    func hostSoftwareUpdateControlMessageSerialization() throws {
        let statusRequest = HostSoftwareUpdateStatusRequestMessage(forceRefresh: true)
        let requestEnvelope = try ControlMessage(type: .hostSoftwareUpdateStatusRequest, content: statusRequest)
        let (decodedRequestEnvelope, _) = try requireParsedControlMessage(from: requestEnvelope.serialize())
        let decodedStatusRequest = try decodedRequestEnvelope.decode(HostSoftwareUpdateStatusRequestMessage.self)
        #expect(decodedStatusRequest.forceRefresh == true)

        let status = HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: true,
            channel: .nightly,
            automationMode: .autoDownload,
            installDisposition: .installing,
            lastBlockReason: nil,
            lastInstallResultCode: .started,
            currentVersion: "1.2.0",
            availableVersion: "1.3.0",
            availableVersionTitle: "Mirage 1.3",
            releaseNotesSummary: "Maintenance release",
            releaseNotesBody: "<ul><li>Improved reliability</li></ul>",
            releaseNotesFormat: .html,
            lastCheckedAtMs: 1_700_000_000_000
        )
        let statusEnvelope = try ControlMessage(type: .hostSoftwareUpdateStatus, content: status)
        let (decodedStatusEnvelope, _) = try requireParsedControlMessage(from: statusEnvelope.serialize())
        let decodedStatus = try decodedStatusEnvelope.decode(HostSoftwareUpdateStatusMessage.self)
        #expect(decodedStatus.channel == .nightly)
        #expect(decodedStatus.availableVersion == "1.3.0")
        #expect(decodedStatus.isInstallInProgress == true)
        #expect(decodedStatus.automationMode == .autoDownload)
        #expect(decodedStatus.installDisposition == .installing)
        #expect(decodedStatus.releaseNotesFormat == .html)

        let installRequest = HostSoftwareUpdateInstallRequestMessage(trigger: .protocolMismatch)
        let installRequestEnvelope = try ControlMessage(type: .hostSoftwareUpdateInstallRequest, content: installRequest)
        let (decodedInstallRequestEnvelope, _) = try requireParsedControlMessage(from: installRequestEnvelope.serialize())
        let decodedInstallRequest = try decodedInstallRequestEnvelope.decode(HostSoftwareUpdateInstallRequestMessage.self)
        #expect(decodedInstallRequest.trigger == .protocolMismatch)

        let installResult = HostSoftwareUpdateInstallResultMessage(
            accepted: false,
            message: "Denied",
            resultCode: .denied,
            blockReason: .policyDenied,
            remediationHint: nil,
            status: status
        )
        let installResultEnvelope = try ControlMessage(type: .hostSoftwareUpdateInstallResult, content: installResult)
        let (decodedInstallResultEnvelope, _) = try requireParsedControlMessage(from: installResultEnvelope.serialize())
        let decodedInstallResult = try decodedInstallResultEnvelope.decode(HostSoftwareUpdateInstallResultMessage.self)
        #expect(decodedInstallResult.accepted == false)
        #expect(decodedInstallResult.status?.currentVersion == "1.2.0")
        #expect(decodedInstallResult.message == "Denied")
        #expect(decodedInstallResult.resultCode == .denied)
        #expect(decodedInstallResult.blockReason == .policyDenied)
    }

    @Test("Audio packet header serialization")
    func audioPacketHeaderSerialization() {
        let header = AudioPacketHeader(
            codec: .pcm16LE,
            flags: [.discontinuity],
            streamID: 7,
            sequenceNumber: 12,
            timestamp: 987_654_321,
            frameNumber: 33,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: 256,
            frameByteCount: 256,
            sampleRate: 44_100,
            channelCount: 2,
            samplesPerFrame: 512,
            checksum: 0xABCD_1234
        )

        let serialized = header.serialize()
        #expect(serialized.count == mirageAudioHeaderSize)
        let decoded = AudioPacketHeader.deserialize(from: serialized)
        #expect(decoded != nil)
        #expect(decoded?.codec == .pcm16LE)
        #expect(decoded?.flags.contains(.discontinuity) == true)
        #expect(decoded?.streamID == 7)
        #expect(decoded?.sampleRate == 44_100)
        #expect(decoded?.channelCount == 2)
        #expect(decoded?.checksum == 0xABCD_1234)
    }

    @Test("Stream encoder settings message serialization")
    func streamEncoderSettingsSerialization() throws {
        let request = StreamEncoderSettingsChangeMessage(
            streamID: 7,
            colorDepth: .pro,
            bitrate: 120_000_000,
            streamScale: 0.75
        )

        let message = try ControlMessage(type: .streamEncoderSettingsChange, content: request)
        let serialized = message.serialize()
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: serialized)
        #expect(consumed == serialized.count)
        #expect(decodedEnvelope.type == .streamEncoderSettingsChange)

        let decodedRequest = try decodedEnvelope.decode(StreamEncoderSettingsChangeMessage.self)
        #expect(decodedRequest.streamID == 7)
        #expect(decodedRequest.colorDepth == .pro)
        #expect(decodedRequest.bitrate == 120_000_000)
        let scale = try #require(decodedRequest.streamScale)
        #expect(abs(Double(scale) - 0.75) < 0.0001)
    }

    @Test("Start stream request latency mode serialization")
    func startStreamLatencyModeSerialization() throws {
        let request = StartStreamMessage(
            windowID: 9,
            dataPort: 5000,
            scaleFactor: 2.0,
            pixelWidth: 3840,
            pixelHeight: 2160,
            displayWidth: 1920,
            displayHeight: 1080,
            keyFrameInterval: 1800,
            captureQueueDepth: 6,
            colorDepth: .pro,
            bitrate: 150_000_000,
            latencyMode: .smoothest,
            performanceMode: .game,
            allowRuntimeQualityAdjustment: true,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 1.0,
            audioConfiguration: .default,
            maxRefreshRate: 60
        )

        let envelope = try ControlMessage(type: .startStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartStreamMessage.self)
        #expect(decoded.latencyMode == .smoothest)
        #expect(decoded.performanceMode == .game)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.bitrate == 150_000_000)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == false)
    }

    @Test("Select app request latency mode serialization")
    func selectAppLatencyModeSerialization() throws {
        let request = SelectAppMessage(
            bundleIdentifier: "com.example.Editor",
            dataPort: 6000,
            scaleFactor: 2.0,
            displayWidth: 1920,
            displayHeight: 1200,
            maxRefreshRate: 120,
            keyFrameInterval: 1800,
            captureQueueDepth: 4,
            colorDepth: .pro,
            bitrate: 200_000_000,
            latencyMode: .lowestLatency,
            performanceMode: .game,
            allowRuntimeQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: true,
            disableResolutionCap: false,
            streamScale: 0.9,
            audioConfiguration: .default
        )

        let envelope = try ControlMessage(type: .selectApp, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(SelectAppMessage.self)
        #expect(decoded.latencyMode == .lowestLatency)
        #expect(decoded.performanceMode == .game)
        #expect(decoded.maxRefreshRate == 120)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == true)
    }

    @Test("Media packet size helpers prefer direct local paths")
    func mediaPacketSizeHelperSelection() {
        #expect(miragePreferredMediaMaxPacketSize(for: .awdl) == 1400)
        #expect(miragePreferredMediaMaxPacketSize(for: .wired) == 1400)
        #expect(miragePreferredMediaMaxPacketSize(for: .wifi) == 1200)
        #expect(mirageNegotiatedMediaMaxPacketSize(requested: 1400, pathKind: .awdl) == 1400)
        #expect(mirageNegotiatedMediaMaxPacketSize(requested: 1400, pathKind: .wifi) == 1200)
    }

    @Test("Stream startup requests serialize media packet sizing")
    func streamStartupRequestsSerializeMediaPacketSizing() throws {
        let startStream = StartStreamMessage(
            windowID: 12,
            dataPort: 5000,
            maxRefreshRate: 60,
            mediaMaxPacketSize: 1400
        )
        let startStreamEnvelope = try ControlMessage(type: .startStream, content: startStream)
        let (decodedStartStreamEnvelope, _) = try requireParsedControlMessage(from: startStreamEnvelope.serialize())
        let decodedStartStream = try decodedStartStreamEnvelope.decode(StartStreamMessage.self)
        #expect(decodedStartStream.mediaMaxPacketSize == 1400)

        let selectApp = SelectAppMessage(
            bundleIdentifier: "com.example.Editor",
            maxRefreshRate: 120,
            maxConcurrentVisibleWindows: 2,
            mediaMaxPacketSize: 1400
        )
        let selectAppEnvelope = try ControlMessage(type: .selectApp, content: selectApp)
        let (decodedSelectAppEnvelope, _) = try requireParsedControlMessage(from: selectAppEnvelope.serialize())
        let decodedSelectApp = try decodedSelectAppEnvelope.decode(SelectAppMessage.self)
        #expect(decodedSelectApp.mediaMaxPacketSize == 1400)

        let startDesktop = StartDesktopStreamMessage(
            scaleFactor: nil,
            displayWidth: 3008,
            displayHeight: 1692,
            maxRefreshRate: 60,
            mediaMaxPacketSize: 1200
        )
        let startDesktopEnvelope = try ControlMessage(type: .startDesktopStream, content: startDesktop)
        let (decodedStartDesktopEnvelope, _) = try requireParsedControlMessage(from: startDesktopEnvelope.serialize())
        let decodedStartDesktop = try decodedStartDesktopEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decodedStartDesktop.mediaMaxPacketSize == 1200)
    }

    @Test("Quality test and started messages serialize accepted media packet sizing")
    func qualityTestAndStartedMessagesSerializeMediaPacketSizing() throws {
        let qualityRequest = QualityTestRequestMessage(
            testID: UUID(),
            plan: MirageQualityTestPlan(stages: []),
            payloadBytes: 1188,
            mediaMaxPacketSize: 1400,
            stopAfterFirstBreach: true
        )
        let qualityEnvelope = try ControlMessage(type: .qualityTestRequest, content: qualityRequest)
        let (decodedQualityEnvelope, _) = try requireParsedControlMessage(from: qualityEnvelope.serialize())
        let decodedQualityRequest = try decodedQualityEnvelope.decode(QualityTestRequestMessage.self)
        #expect(decodedQualityRequest.mediaMaxPacketSize == 1400)
        #expect(decodedQualityRequest.stopAfterFirstBreach)

        let started = StreamStartedMessage(
            streamID: 42,
            windowID: 12,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: .hevc,
            acceptedMediaMaxPacketSize: 1400
        )
        let startedEnvelope = try ControlMessage(type: .streamStarted, content: started)
        let (decodedStartedEnvelope, _) = try requireParsedControlMessage(from: startedEnvelope.serialize())
        let decodedStarted = try decodedStartedEnvelope.decode(StreamStartedMessage.self)
        #expect(decodedStarted.acceptedMediaMaxPacketSize == 1400)

        let desktopStarted = DesktopStreamStartedMessage(
            streamID: 77,
            width: 3008,
            height: 1692,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            acceptedMediaMaxPacketSize: 1200
        )
        let desktopStartedEnvelope = try ControlMessage(type: .desktopStreamStarted, content: desktopStarted)
        let (decodedDesktopStartedEnvelope, _) = try requireParsedControlMessage(from: desktopStartedEnvelope.serialize())
        let decodedDesktopStarted = try decodedDesktopStartedEnvelope.decode(DesktopStreamStartedMessage.self)
        #expect(decodedDesktopStarted.acceptedMediaMaxPacketSize == 1200)
    }

    @Test("Window removed from stream payload serialization")
    func windowRemovedFromStreamSerialization() throws {
        let payload = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowID: 12615,
            reason: .noLongerEligible
        )

        let envelope = try ControlMessage(type: .windowRemovedFromStream, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(WindowRemovedFromStreamMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decoded.windowID == 12615)
        #expect(decoded.reason == .noLongerEligible)
    }

    @Test("Window stream failed payload serialization")
    func windowStreamFailedSerialization() throws {
        let payload = WindowStreamFailedMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowID: 14674,
            title: "PokeApp — CanvasGreetingOverlay.swift",
            reason: "Dedicated display correction failed"
        )

        let envelope = try ControlMessage(type: .windowStreamFailed, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(WindowStreamFailedMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decoded.windowID == 14674)
        #expect(decoded.title == "PokeApp — CanvasGreetingOverlay.swift")
        #expect(decoded.reason == "Dedicated display correction failed")
    }

    @Test("Desktop stream failed payload serialization")
    func desktopStreamFailedSerialization() throws {
        let payload = DesktopStreamFailedMessage(
            reason: "Virtual display failed activation",
            errorCode: .virtualDisplayStartFailed
        )

        let envelope = try ControlMessage(type: .desktopStreamFailed, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(DesktopStreamFailedMessage.self)
        #expect(decoded.reason == "Virtual display failed activation")
        #expect(decoded.errorCode == .virtualDisplayStartFailed)
    }

    @Test("App window control message IDs are registered")
    func appWindowControlMessageTypeIDsRegistered() {
        #expect(ControlMessageType(rawValue: 0x87) == .appWindowInventory)
        #expect(ControlMessageType(rawValue: 0x88) == .appWindowSwapRequest)
        #expect(ControlMessageType(rawValue: 0x89) == .appWindowCloseBlockedAlert)
        #expect(ControlMessageType(rawValue: 0x8A) == .appWindowCloseAlertActionRequest)
        #expect(ControlMessageType(rawValue: 0x8B) == .appWindowCloseAlertActionResult)
        #expect(ControlMessageType(rawValue: 0x8C) == .appWindowSwapResult)
        #expect(ControlMessageType(rawValue: 0x95) == .appIconUpdate)
        #expect(ControlMessageType(rawValue: 0x96) == .appIconStreamComplete)
    }

    @Test("App window close-blocked alert payload serialization")
    func appWindowCloseBlockedAlertSerialization() throws {
        let payload = AppWindowCloseBlockedAlertMessage(
            bundleIdentifier: "com.apple.TextEdit",
            sourceWindowID: 901,
            presentingStreamID: 41,
            alertToken: "token-123",
            title: "Save changes?",
            message: "Do you want to save the changes made to this document?",
            actions: [
                .init(id: "action-0", title: "Cancel"),
                .init(id: "action-1", title: "Don't Save", isDestructive: true),
                .init(id: "action-2", title: "Save")
            ]
        )

        let envelope = try ControlMessage(type: .appWindowCloseBlockedAlert, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseBlockedAlertMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.TextEdit")
        #expect(decoded.sourceWindowID == 901)
        #expect(decoded.presentingStreamID == 41)
        #expect(decoded.alertToken == "token-123")
        #expect(decoded.actions.count == 3)
        #expect(decoded.actions[1].isDestructive)
    }

    @Test("App window close-alert action request payload serialization")
    func appWindowCloseAlertActionRequestSerialization() throws {
        let payload = AppWindowCloseAlertActionRequestMessage(
            alertToken: "token-abc",
            actionID: "action-2",
            presentingStreamID: 73
        )

        let envelope = try ControlMessage(type: .appWindowCloseAlertActionRequest, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseAlertActionRequestMessage.self)
        #expect(decoded.alertToken == "token-abc")
        #expect(decoded.actionID == "action-2")
        #expect(decoded.presentingStreamID == 73)
    }

    @Test("App window close-alert action result payload serialization")
    func appWindowCloseAlertActionResultSerialization() throws {
        let payload = AppWindowCloseAlertActionResultMessage(
            alertToken: "token-result",
            actionID: "action-1",
            success: false,
            reason: "Presenting stream mismatch"
        )

        let envelope = try ControlMessage(type: .appWindowCloseAlertActionResult, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseAlertActionResultMessage.self)
        #expect(decoded.alertToken == "token-result")
        #expect(decoded.actionID == "action-1")
        #expect(decoded.success == false)
        #expect(decoded.reason == "Presenting stream mismatch")
    }

    @Test("Stop stream origin serialization")
    func stopStreamOriginSerialization() throws {
        let payload = StopStreamMessage(
            streamID: 55,
            minimizeWindow: false,
            origin: .clientWindowClosed
        )

        let envelope = try ControlMessage(type: .stopStream, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StopStreamMessage.self)
        #expect(decoded.streamID == 55)
        #expect(decoded.minimizeWindow == false)
        #expect(decoded.origin == .clientWindowClosed)
    }

    @Test("Start desktop request latency mode serialization")
    func startDesktopLatencyModeSerialization() throws {
        let request = StartDesktopStreamMessage(
            scaleFactor: 2.0,
            displayWidth: 3008,
            displayHeight: 1692,
            keyFrameInterval: 1800,
            captureQueueDepth: 5,
            colorDepth: .pro,
            mode: .mirrored,
            bitrate: 500_000_000,
            latencyMode: .auto,
            performanceMode: .game,
            allowRuntimeQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 1.0,
            audioConfiguration: .default,
            dataPort: 63220,
            maxRefreshRate: 60
        )

        let envelope = try ControlMessage(type: .startDesktopStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decoded.latencyMode == .auto)
        #expect(decoded.performanceMode == .game)
        #expect(decoded.displayWidth == 3008)
        #expect(decoded.displayHeight == 1692)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == false)
    }

    @Test("Start desktop request cursor presentation serialization")
    func startDesktopCursorPresentationSerialization() throws {
        let request = StartDesktopStreamMessage(
            scaleFactor: 2.0,
            displayWidth: 3008,
            displayHeight: 1692,
            mode: .secondary,
            cursorPresentation: MirageDesktopCursorPresentation(
                source: .host,
                lockClientCursorWhenUsingMirageCursor: true,
                lockClientCursorWhenUsingHostCursor: false
            ),
            audioConfiguration: .default,
            dataPort: 63220,
            maxRefreshRate: 120
        )

        let envelope = try ControlMessage(type: .startDesktopStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decoded.cursorPresentation?.source == .host)
        #expect(decoded.cursorPresentation?.lockClientCursorWhenUsingMirageCursor == true)
        #expect(decoded.cursorPresentation?.lockClientCursorWhenUsingHostCursor == false)
    }

    @Test("Desktop cursor presentation change message serialization")
    func desktopCursorPresentationChangeSerialization() throws {
        let request = DesktopCursorPresentationChangeMessage(
            streamID: 42,
            cursorPresentation: MirageDesktopCursorPresentation(
                source: .host,
                lockClientCursorWhenUsingMirageCursor: false,
                lockClientCursorWhenUsingHostCursor: true
            )
        )

        let envelope = try ControlMessage(type: .desktopCursorPresentationChange, content: request)
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        let decoded = try decodedEnvelope.decode(DesktopCursorPresentationChangeMessage.self)
        #expect(decoded.streamID == 42)
        #expect(decoded.cursorPresentation.source == .host)
        #expect(decoded.cursorPresentation.lockClientCursorWhenUsingMirageCursor == false)
        #expect(decoded.cursorPresentation.lockClientCursorWhenUsingHostCursor)
    }

    @Test("Start stream request omits performance mode when unset")
    func startStreamPerformanceModeDefaultSerialization() throws {
        let request = StartStreamMessage(
            windowID: 11,
            maxRefreshRate: 60
        )

        let envelope = try ControlMessage(type: .startStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartStreamMessage.self)
        #expect(decoded.performanceMode == nil)
    }

    @Test("Stream metrics validation payload serialization")
    func streamMetricsValidationPayloadSerialization() throws {
        let metrics = StreamMetricsMessage(
            streamID: 1,
            encodedFPS: 58.0,
            idleEncodedFPS: 0.2,
            droppedFrames: 12,
            activeQuality: 0.74,
            targetFrameRate: 60,
            averageEncodeMs: 13.2,
            captureIngressAverageMs: 4.1,
            captureIngressMaxMs: 10.9,
            preEncodeWaitAverageMs: 5.6,
            preEncodeWaitMaxMs: 12.4,
            captureCallbackAverageMs: 1.8,
            captureCallbackMaxMs: 4.2,
            captureCopyAverageMs: 2.4,
            captureCopyMaxMs: 5.7,
            captureCopyPoolDrops: 2,
            captureCopyInFlightDrops: 3,
            sendQueueBytes: 262_144,
            sendStartDelayAverageMs: 3.7,
            sendStartDelayMaxMs: 8.8,
            sendCompletionAverageMs: 9.4,
            sendCompletionMaxMs: 21.1,
            packetPacerAverageSleepMs: 1.3,
            packetPacerMaxSleepMs: 6,
            stalePacketDrops: 1,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 4,
            usingHardwareEncoder: true,
            encoderGPURegistryID: 12345,
            capturePixelFormat: "xf20",
            captureColorPrimaries: kCVImageBufferColorPrimaries_P3_D65 as String,
            encoderPixelFormat: "10-bit (P010)",
            encoderProfile: "HEVC Main10 (4:2:0)",
            encoderColorPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65 as String,
            encoderTransferFunction: kCMFormatDescriptionTransferFunction_sRGB as String,
            encoderYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            tenBitDisplayP3Validated: true
        )

        let envelope = try ControlMessage(type: .streamMetricsUpdate, content: metrics)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StreamMetricsMessage.self)
        #expect(decoded.averageEncodeMs == 13.2)
        #expect(decoded.captureIngressAverageMs == 4.1)
        #expect(decoded.captureCopyPoolDrops == 2)
        #expect(decoded.sendQueueBytes == 262_144)
        #expect(decoded.sendCompletionMaxMs == 21.1)
        #expect(decoded.nonKeyframeHoldDrops == 4)
        #expect(decoded.usingHardwareEncoder == true)
        #expect(decoded.encoderGPURegistryID == 12345)
        #expect(decoded.capturePixelFormat == "xf20")
        #expect(decoded.encoderProfile == "HEVC Main10 (4:2:0)")
        #expect(decoded.tenBitDisplayP3Validated == true)
    }

    @Test("Stream metrics validation mismatch serialization")
    func streamMetricsValidationMismatchSerialization() throws {
        let metrics = StreamMetricsMessage(
            streamID: 2,
            encodedFPS: 42.0,
            idleEncodedFPS: 0,
            droppedFrames: 101,
            activeQuality: 0.68,
            targetFrameRate: 60,
            capturePixelFormat: "420v",
            captureColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            encoderPixelFormat: "8-bit (NV12)",
            encoderProfile: "HEVC Main (4:2:0)",
            encoderColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            encoderTransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            encoderYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            tenBitDisplayP3Validated: false
        )

        let envelope = try ControlMessage(type: .streamMetricsUpdate, content: metrics)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StreamMetricsMessage.self)
        #expect(decoded.averageEncodeMs == nil)
        #expect(decoded.usingHardwareEncoder == nil)
        #expect(decoded.encoderGPURegistryID == nil)
        #expect(decoded.capturePixelFormat == "420v")
        #expect(decoded.encoderPixelFormat == "8-bit (NV12)")
        #expect(decoded.tenBitDisplayP3Validated == false)
    }

    @Test("MirageWindow equality")
    func windowEquality() {
        let window1 = MirageWindow(
            id: 1,
            title: "Test Window",
            application: nil,
            frame: .zero,
            isOnScreen: true,
            windowLayer: 0
        )

        let window2 = MirageWindow(
            id: 1,
            title: "Test Window",
            application: nil,
            frame: .zero,
            isOnScreen: true,
            windowLayer: 0
        )

        #expect(window1 == window2)
        #expect(window1.hashValue == window2.hashValue)
    }

    @Test("Peer advertisement TXT record")
    func peerAdvertisementTXTRecord() {
        let deviceID = UUID()
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: deviceID,
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            supportedColorDepths: [.standard, .pro]
        )

        let txtRecord = advertisement.toTXTRecord()
        #expect(txtRecord["proto"] == String(Int(MirageKit.protocolVersion)))
        #expect(txtRecord["did"] == deviceID.uuidString)
        #expect(txtRecord["ikid"] == "test-key-id")
        #expect(txtRecord["dt"] == DeviceType.mac.rawValue)
        #expect(txtRecord["model"] == "Mac16,1")
        #expect(txtRecord["icon"] == "desktopcomputer")
        #expect(txtRecord["family"] == "Mac")

        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(decoded.protocolVersion == Int(MirageKit.protocolVersion))
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.identityKeyID == "test-key-id")
        #expect(decoded.deviceType == .mac)
        #expect(decoded.hostName == MiragePeerAdvertisementMetadata.advertisedBonjourHostName())
        #expect(MiragePeerAdvertisementMetadata.maxStreams(from: decoded) == 4)
        #expect(MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportsHEVC(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: decoded) == true)
        #expect(MiragePeerAdvertisementMetadata.supportedColorDepths(in: decoded) == [.standard, .pro])
        #expect(MiragePeerAdvertisementMetadata.maxFrameRate(from: decoded) == 120)
        #expect(decoded.mirageAcceptingConnections == true)
    }

    @Test("Peer advertisement busy flag round trips")
    func peerAdvertisementBusyFlagRoundTrips() {
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "test-key-id",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: false,
            supportedColorDepths: [.standard]
        )

        let txtRecord = advertisement.toTXTRecord()
        let decoded = LoomPeerAdvertisement.from(txtRecord: txtRecord)
        #expect(MiragePeerAdvertisementMetadata.acceptingConnections(in: decoded) == false)
        #expect(decoded.mirageAcceptingConnections == false)
    }

    @Test("Peer advertisement busy flag defaults to available")
    func peerAdvertisementBusyFlagDefaultsToAvailable() {
        let advertisement = LoomPeerAdvertisement(deviceType: .mac)
        #expect(MiragePeerAdvertisementMetadata.acceptingConnections(in: advertisement) == true)
        #expect(advertisement.mirageAcceptingConnections == true)
    }

    @Test("Peer advertisement local network context round trips and preserves host fields")
    func peerAdvertisementLocalNetworkContextRoundTrips() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: UUID(),
            identityKeyID: "host-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: "Altair.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: 61001),
            ],
            metadata: [
                "mirage.accepting-connections": "1",
            ]
        )

        let updated = MiragePeerAdvertisementMetadata.updatingLocalNetworkContext(
            MirageLocalNetworkSnapshot(
                currentPathKind: .wifi,
                wifiSubnetSignatures: ["24:wifi-a", "24:wifi-b"],
                wiredSubnetSignatures: ["24:wired-a"]
            ),
            in: advertisement
        )
        let decoded = LoomPeerAdvertisement.from(txtRecord: updated.toTXTRecord())
        let networkContext = MiragePeerAdvertisementMetadata.advertisedLocalNetworkContext(from: decoded)

        #expect(decoded.hostName == "Altair.local")
        #expect(decoded.directTransports == advertisement.directTransports)
        #expect(networkContext.wifiSubnetSignatures == ["24:wifi-a", "24:wifi-b"])
        #expect(networkContext.wiredSubnetSignatures == ["24:wired-a"])
    }

    @Test("Host advertisement VPN access metadata serialization")
    func hostAdvertisementVPNAccessMetadataSerialization() throws {
        let advertisement = MiragePeerAdvertisementMetadata.makeHostAdvertisement(
            deviceID: UUID(),
            identityKeyID: "host-key",
            modelIdentifier: "Mac16,1",
            iconName: "desktopcomputer",
            machineFamily: "Mac",
            hostName: MiragePeerAdvertisementMetadata.advertisedBonjourHostName(),
            acceptingConnections: true,
            vpnAccessEnabled: true,
            supportedColorDepths: [.standard, .pro]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: advertisement.toTXTRecord())

        #expect(decoded.mirageAcceptingConnections == true)
        #expect(decoded.mirageVPNAccessEnabled == true)
    }

    @Test("Advertised Bonjour host name normalizes local host names")
    func advertisedBonjourHostNameNormalization() {
        #expect(
            MiragePeerAdvertisementMetadata.advertisedBonjourHostName(
                processHostName: "Ethans-Mac-Studio"
            ) == "Ethans-Mac-Studio.local"
        )
        #expect(
            MiragePeerAdvertisementMetadata.advertisedBonjourHostName(
                processHostName: "Ethans-Mac-Studio.local"
            ) == "Ethans-Mac-Studio.local"
        )
        #expect(
            MiragePeerAdvertisementMetadata.advertisedBonjourHostName(
                processHostName: "Ethan’s Mac Studio"
            ) == "Ethan’s-Mac-Studio.local"
        )
    }

    @Test("Stream statistics formatting")
    func statisticsFormatting() {
        let stats = MirageStreamStatistics(
            currentFrameRate: 120,
            processedFrames: 1000,
            droppedFrames: 5,
            averageLatencyMs: 25.5
        )

        #expect(stats.formattedLatency == "25.5 ms")
        #expect(stats.dropRate < 0.01)
    }
}
