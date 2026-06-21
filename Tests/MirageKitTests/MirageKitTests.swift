//
//  MirageKitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Loom
@testable import MirageKit
import Testing

@Suite("MirageKit Tests")
struct MirageKitTests {
    @Test("Stream statistics drop rate uses total observed frames")
    func streamStatisticsDropRateUsesTotalObservedFrames() {
        #expect(MirageStreamStatistics(processedFrames: 0, droppedFrames: 0).dropRate == 0)
        #expect(MirageStreamStatistics(processedFrames: 0, droppedFrames: 3).dropRate == 1)
        #expect(MirageStreamStatistics(processedFrames: 7, droppedFrames: 3).dropRate == 0.3)
        #expect(MirageStreamStatistics(processedFrames: .max, droppedFrames: .max).dropRate == 0.5)
    }

    @Test("AWDL media packet sizing reserves Loom transport overhead")
    func awdlMediaPacketSizingReservesLoomTransportOverhead() {
        #expect(miragePreferredMediaMaxPacketSize(for: .awdl) == mirageDirectProximityMaxPacketSize)
        #expect(mirageDirectProximityMaxPacketSize < mirageDefaultMaxPacketSize)
        #expect(miragePreferredMediaMaxPacketSize(
            for: MirageMediaPathProfile.awdlRadio,
            pathKind: .awdl
        ) == mirageDirectProximityMaxPacketSize)
        #expect(miragePreferredMediaMaxPacketSize(
            for: MirageMediaPathProfile.proximityWiredLike,
            pathKind: .awdl
        ) == mirageDirectLocalMaxPacketSize)
        #expect(miragePreferredMediaMaxPacketSize(for: .wifi) == mirageDirectWiFiMaxPacketSize)
        #expect(miragePreferredMediaMaxPacketSize(for: .wired) == mirageDirectLocalMaxPacketSize)
    }

    @Test("Background lease payload requires mode")
    func backgroundLeasePayloadRequiresMode() {
        let leaseID = UUID(uuidString: "AC5DC09D-FA66-48BB-89C9-5EC4702CB6A0")!
        let payload = """
        {"leaseID":"\(leaseID.uuidString)","durationSeconds":120}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                ClientBackgroundLeaseMessage.self,
                from: payload
            )
        }
    }

    @Test("Background timed lease payload round trips mode")
    func backgroundTimedLeasePayloadRoundTripsMode() throws {
        let lease = ClientBackgroundLeaseMessage(
            leaseID: UUID(uuidString: "AC5DC09D-FA66-48BB-89C9-5EC4702CB6A0")!,
            durationSeconds: 120,
            mode: .timed
        )
        let encoded = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(
            ClientBackgroundLeaseMessage.self,
            from: encoded
        )

        #expect(decoded == lease)
    }

    @Test("Background suspended lease payload round trips mode")
    func backgroundSuspendedLeasePayloadRoundTripsMode() throws {
        let lease = ClientBackgroundLeaseMessage(
            leaseID: UUID(uuidString: "3079EC2B-4240-464A-92BB-2BDE2746E990")!,
            durationSeconds: 120,
            mode: .suspendedUntilForeground
        )

        let encoded = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(
            ClientBackgroundLeaseMessage.self,
            from: encoded
        )

        #expect(decoded == lease)
    }

    @Test("Default stream cadence uses lowest latency")
    func defaultStreamCadenceUsesLowestLatency() {
        let target = MirageStreamCadenceTarget(sourceFPS: 60)

        #expect(target.latencyMode == .lowestLatency)
        #expect(target.playoutDelayFrames == 0)
    }

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
        #expect(deserialized?.version == 260604)
        #expect(deserialized?.version == MirageKit.protocolVersion)
        #expect(deserialized?.streamID == 1)
        #expect(deserialized?.sequenceNumber == 100)
        #expect(deserialized?.frameNumber == 50)
        #expect(deserialized?.flags.contains(FrameFlags.keyframe) == true)
    }

    @Test("Control message serialization")
    func controlMessageSerialization() throws {
        let connectionAttemptID = try #require(UUID(uuidString: "4DF97645-633E-4D7B-987C-6F0E40B7D295"))
        let bootstrap = MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.protocolVersion),
            clientRequiresMediaEncryption: true,
            connectionAttemptID: connectionAttemptID,
            adaptiveGovernorRevision: 2,
            hostOwnedRuntimeSupport: true,
            adaptiveFeedbackClassesSupported: ["hard", "soft", "diagnostic"],
            adaptiveLegacyFallbackMode: "legacy-passive-fallback"
        )

        let message = try ControlMessage(type: .sessionBootstrapRequest, content: bootstrap)
        let data = message.serialize()

        let (deserialized, consumed) = try requireParsedControlMessage(from: data)
        #expect(consumed == data.count)
        #expect(deserialized.type == .sessionBootstrapRequest)

        let decodedBootstrap = try deserialized.decode(MirageSessionBootstrapRequest.self)
        #expect(MirageKit.protocolVersion == 260604)
        #expect(decodedBootstrap.protocolVersion == Int(MirageKit.protocolVersion))
        #expect(decodedBootstrap.clientRequiresMediaEncryption)
        #expect(decodedBootstrap.connectionAttemptID == connectionAttemptID)
        #expect(decodedBootstrap.adaptiveGovernorRevision == 2)
        #expect(decodedBootstrap.hostOwnedRuntimeSupport == true)
        #expect(decodedBootstrap.adaptiveFeedbackClassesSupported == ["hard", "soft", "diagnostic"])
        #expect(decodedBootstrap.adaptiveLegacyFallbackMode == "legacy-passive-fallback")

        let legacyBootstrap = MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.protocolVersion),
            clientRequiresMediaEncryption: true
        )
        let legacyMessage = try ControlMessage(type: .sessionBootstrapRequest, content: legacyBootstrap)
        let (decodedLegacyMessage, _) = try requireParsedControlMessage(from: legacyMessage.serialize())
        let decodedLegacyBootstrap = try decodedLegacyMessage.decode(MirageSessionBootstrapRequest.self)
        #expect(decodedLegacyBootstrap.connectionAttemptID == nil)
    }

    @Test("Legacy quality-test control message IDs remain parseable")
    func legacyQualityTestControlMessageIDsRemainParseable() throws {
        for type in [
            ControlMessageType.qualityTestRequest,
            .qualityTestResult,
            .qualityTestStageComplete,
            .qualityTestCancel
        ] {
            let message = ControlMessage(type: type)
            let (decoded, consumed) = try requireParsedControlMessage(from: message.serialize())
            #expect(consumed == message.serialize().count)
            #expect(decoded.type == type)
        }
    }

    @Test("Keyframe recovery ack serializes on control channel")
    func keyframeRecoveryAckSerialization() throws {
        let ack = KeyframeRecoveryAckMessage(
            streamID: 9,
            deadlineMilliseconds: 350
        )

        let message = try ControlMessage(type: .keyframeRecoveryAck, content: ack)
        let (parsed, consumed) = try requireParsedControlMessage(from: message.serialize())
        let decoded = try parsed.decode(KeyframeRecoveryAckMessage.self)

        #expect(consumed == message.serialize().count)
        #expect(parsed.type == .keyframeRecoveryAck)
        #expect(decoded == ack)
    }

    @Test("Desktop stream start rejects unknown optional enum preferences")
    func desktopStreamStartRejectsUnknownOptionalPreferences() {
        let payload = Data(
            """
            {
              "startupRequestID": "00000000-0000-0000-0000-000000000101",
              "displayWidth": 1366,
              "displayHeight": 1024,
              "targetFrameRate": 60,
              "mode": "future-mode",
              "colorDepth": "future-depth",
              "latencyMode": "future-latency",
              "audioConfiguration": {
                "enabled": true,
                "channelLayout": "future-layout",
                "quality": "high"
              },
              "codec": "future-codec",
              "upscalingMode": "future-upscaler",
              "disableResolutionCap": true
            }
            """.utf8
        )

        #expect(throws: Error.self) {
            try JSONDecoder().decode(StartDesktopStreamMessage.self, from: payload)
        }
    }

    @Test("Desktop stream start rejects removed auto latency")
    func desktopStreamStartRejectsRemovedAutoLatency() {
        let payload = Data(
            """
            {
              "startupRequestID": "00000000-0000-0000-0000-000000000102",
              "displayWidth": 1366,
              "displayHeight": 1024,
              "targetFrameRate": 60,
              "latencyMode": "auto"
            }
            """.utf8
        )

        #expect(throws: Error.self) {
            try JSONDecoder().decode(StartDesktopStreamMessage.self, from: payload)
        }
    }

    @Test("Latency mode rejects removed auto value")
    func latencyModeRejectsRemovedAutoValue() {
        let payload = Data(#""auto""#.utf8)

        #expect(throws: Error.self) {
            try JSONDecoder().decode(MirageStreamLatencyMode.self, from: payload)
        }
    }

    @Test("Balanced latency mode round trips")
    func balancedLatencyModeRoundTrips() throws {
        let encoded = try JSONEncoder().encode(MirageStreamLatencyMode.balanced)
        let decoded = try JSONDecoder().decode(MirageStreamLatencyMode.self, from: encoded)

        #expect(decoded == .balanced)
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

    @Test("Display-resolution change serializes desktop resize transition metadata")
    func displayResolutionChangeSerializesDesktopResizeTransitionMetadata() throws {
        let transitionID = UUID()
        let payload = DisplayResolutionChangeMessage(
            streamID: 41,
            displayWidth: 1440,
            displayHeight: 900,
            transitionID: transitionID,
            requestedDisplayScaleFactor: 2.0,
            requestedStreamScale: 1.0,
            encoderMaxWidth: 2360,
            encoderMaxHeight: 1640
        )
        let envelope = try ControlMessage(type: .displayResolutionChange, content: payload)

        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        let decodedPayload = try decodedEnvelope.decode(DisplayResolutionChangeMessage.self)

        #expect(decodedPayload.streamID == 41)
        #expect(decodedPayload.displayWidth == 1440)
        #expect(decodedPayload.displayHeight == 900)
        #expect(decodedPayload.transitionID == transitionID)
        #expect(decodedPayload.requestedDisplayScaleFactor == 2.0)
        #expect(decodedPayload.requestedStreamScale == 1.0)
        #expect(decodedPayload.encoderMaxWidth == 2360)
        #expect(decodedPayload.encoderMaxHeight == 1640)
    }

    @Test("Desktop-stream started serializes resize transition metadata")
    func desktopStreamStartedSerializesResizeTransitionMetadata() throws {
        let desktopSessionID = UUID()
        let transitionID = UUID()
        let payload = DesktopStreamStartedMessage(
            streamID: 71,
            desktopSessionID: desktopSessionID,
            width: 3024,
            height: 1964,
            frameRate: 120,
            codec: .hevc,
            displayCount: 1,
            dimensionToken: 7,
            acceptedMediaMaxPacketSize: 1400,
            transitionID: transitionID,
            transitionPhase: .resize,
            transitionOutcome: .rolledBack
        )
        let envelope = try ControlMessage(type: .desktopStreamStarted, content: payload)

        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        let decodedPayload = try decodedEnvelope.decode(DesktopStreamStartedMessage.self)

        #expect(decodedPayload.streamID == 71)
        #expect(decodedPayload.desktopSessionID == desktopSessionID)
        #expect(decodedPayload.width == 3024)
        #expect(decodedPayload.height == 1964)
        #expect(decodedPayload.dimensionToken == 7)
        #expect(decodedPayload.transitionID == transitionID)
        #expect(decodedPayload.transitionPhase == .resize)
        #expect(decodedPayload.transitionOutcome == .rolledBack)
    }

    @Test("Desktop-stream started serializes fallback capture policy")
    func desktopStreamStartedSerializesFallbackCapturePolicy() throws {
        let payload = DesktopStreamStartedMessage(
            streamID: 72,
            desktopSessionID: UUID(),
            width: 5120,
            height: 2880,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            captureSource: .mainDisplayFallback,
            allowsClientResize: false,
            acceptedDisplayScaleFactor: 1.72,
            presentationWidth: 2732,
            presentationHeight: 1537
        )
        let envelope = try ControlMessage(type: .desktopStreamStarted, content: payload)

        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decodedPayload = try decodedEnvelope.decode(DesktopStreamStartedMessage.self)

        #expect(decodedPayload.captureSource == .mainDisplayFallback)
        #expect(decodedPayload.allowsClientResize == false)
        #expect(decodedPayload.acceptedDisplayScaleFactor == 1.72)
        #expect(decodedPayload.presentationSize == CGSize(width: 2732, height: 1537))
    }

    @Test("Desktop-stream started serializes app placeholder metadata")
    func desktopStreamStartedSerializesAppPlaceholderMetadata() throws {
        let appSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000A11"))
        let startupRequestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000A12"))
        let payload = DesktopStreamStartedMessage(
            streamID: 73,
            desktopSessionID: UUID(),
            width: 2732,
            height: 2048,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            presentationRole: .appStreamPlaceholder,
            associatedAppSessionID: appSessionID,
            associatedAppStartupRequestID: startupRequestID,
            associatedBundleIdentifier: "com.apple.mail"
        )

        let envelope = try ControlMessage(type: .desktopStreamStarted, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decodedPayload = try decodedEnvelope.decode(DesktopStreamStartedMessage.self)

        #expect(decodedPayload.presentationRole == .appStreamPlaceholder)
        #expect(decodedPayload.associatedAppSessionID == appSessionID)
        #expect(decodedPayload.associatedAppStartupRequestID == startupRequestID)
        #expect(decodedPayload.associatedBundleIdentifier == "com.apple.mail")
    }

    @Test("Desktop stream stop messages serialize desktop session identifiers")
    func desktopStreamStopMessagesSerializeDesktopSessionIdentifiers() throws {
        let desktopSessionID = UUID()

        let stopRequest = StopDesktopStreamMessage(
            streamID: 33,
            desktopSessionID: desktopSessionID
        )
        let stopRequestEnvelope = try ControlMessage(type: .stopDesktopStream, content: stopRequest)
        let (decodedStopRequestEnvelope, _) = try requireParsedControlMessage(from: stopRequestEnvelope.serialize())
        let decodedStopRequest = try decodedStopRequestEnvelope.decode(StopDesktopStreamMessage.self)
        #expect(decodedStopRequest.streamID == 33)
        #expect(decodedStopRequest.desktopSessionID == desktopSessionID)

        let stopped = DesktopStreamStoppedMessage(
            streamID: 33,
            desktopSessionID: desktopSessionID,
            reason: .clientRequested
        )
        let stoppedEnvelope = try ControlMessage(type: .desktopStreamStopped, content: stopped)
        let (decodedStoppedEnvelope, _) = try requireParsedControlMessage(from: stoppedEnvelope.serialize())
        let decodedStopped = try decodedStoppedEnvelope.decode(DesktopStreamStoppedMessage.self)
        #expect(decodedStopped.streamID == 33)
        #expect(decodedStopped.desktopSessionID == desktopSessionID)
        #expect(decodedStopped.reason == .clientRequested)
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

    @Test("Control parser rejects oversized app-list progress payload")
    func controlParserRejectsOversizedAppListProgressPayload() {
        var data = Data([ControlMessageType.appListProgress.rawValue])
        let oversizedLength = UInt32(LoomMessageLimits.maxLargeMetadataPayloadBytes + 1)
        withUnsafeBytes(of: oversizedLength.littleEndian) { data.append(contentsOf: $0) }

        switch ControlMessage.deserialize(from: data) {
        case .invalidFrame:
            break
        default:
            Issue.record("Expected invalidFrame for oversized app-list progress payload.")
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
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let wallpaper = HostWallpaperMessage(
            requestID: UUID(),
            imageData: imageData,
            pixelWidth: 854,
            pixelHeight: 480
        )

        let envelope = try ControlMessage(type: .hostWallpaper, content: wallpaper)
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        #expect(decodedEnvelope.type == .hostWallpaper)

        let decoded = try decodedEnvelope.decode(HostWallpaperMessage.self)
        #expect(decoded.requestID == wallpaper.requestID)
        #expect(decoded.imageData == imageData)
        #expect(decoded.pixelWidth == 854)
        #expect(decoded.pixelHeight == 480)
    }

    @Test("Bootstrap response mismatch metadata serialization")
    func bootstrapResponseMismatchMetadataSerialization() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 1,
            protocolMismatchClientVersion: 2
        )

        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)
        #expect(decoded.rejectionReason == .protocolVersionMismatch)
        #expect(decoded.protocolMismatchHostVersion == 1)
        #expect(decoded.protocolMismatchClientVersion == 2)
    }

    @Test("Accepted bootstrap response off-LAN access metadata serialization")
    func bootstrapResponseRemoteAccessMetadataSerialization() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: true,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: true,
            datagramRegistrationToken: Data(
                repeating: 0xAB,
                count: MirageMediaSecurity.registrationTokenLength
            ),
            remoteAccessAllowed: true,
            adaptiveGovernorRevision: 2,
            hostOwnedRuntimeSupport: true,
            adaptiveFeedbackClassesSupported: ["hard", "soft"],
            adaptiveLegacyFallbackMode: "legacy-passive-fallback"
        )

        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)

        #expect(decoded.accepted == true)
        #expect(decoded.remoteAccessAllowed == true)
        #expect(decoded.adaptiveGovernorRevision == 2)
        #expect(decoded.hostOwnedRuntimeSupport == true)
        #expect(decoded.adaptiveFeedbackClassesSupported == ["hard", "soft"])
        #expect(decoded.adaptiveLegacyFallbackMode == "legacy-passive-fallback")
    }

    @Test("Bootstrap response authorization failure metadata serialization")
    func bootstrapResponseAuthorizationFailureMetadataSerialization() throws {
        let response = MirageSessionBootstrapResponse(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: .unauthorized,
            authorizationFailureReason: .remoteAccessDisabled
        )

        let envelope = try ControlMessage(type: .sessionBootstrapResponse, content: response)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(MirageSessionBootstrapResponse.self)

        #expect(decoded.rejectionReason == .unauthorized)
        #expect(decoded.authorizationFailureReason == .remoteAccessDisabled)
    }

    @Test("Audio control message serialization")
    func audioControlMessageSerialization() throws {
        let started = AudioStreamStartedMessage(
            streamID: 42,
            codec: .aacLC,
            sampleRate: 48000,
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
            reason: "send-error-burst"
        )
        let envelope = try ControlMessage(type: .transportRefreshRequest, content: refresh)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(decodedEnvelope.type == .transportRefreshRequest)
        let decoded = try decodedEnvelope.decode(TransportRefreshRequestMessage.self)
        #expect(decoded.streamID == 7)
        #expect(decoded.reason == "send-error-burst")
    }

}
