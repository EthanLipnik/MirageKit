//
//  MirageMediaTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageMedia
import Testing

@Suite("MirageMedia")
struct MirageMediaTests {
    @Test("Media strategies keep expected wire names")
    func mediaStrategiesKeepExpectedWireNames() throws {
        #expect(MirageMediaStrategy.allCases == [.fullFrameHEVC, .appAtlas, .custom])

        let encoded = try JSONEncoder().encode(MirageMediaStrategy.fullFrameHEVC)
        let decoded = try JSONDecoder().decode(MirageMediaStrategy.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"fullFrameHEVC\"")
        #expect(decoded == .fullFrameHEVC)
    }

    @Test("Stream presentation models preserve session family and logical policy")
    func streamPresentationModelsPreserveSessionFamilyAndLogicalPolicy() throws {
        let ownerID = try #require(UUID(uuidString: "32000000-0000-0000-0000-000000000001"))
        let presentationID = try #require(UUID(uuidString: "32000000-0000-0000-0000-000000000002"))
        let request = MirageMedia.StreamPresentationRequest(
            id: presentationID,
            kind: .desktop,
            ownerID: ownerID,
            requestedSize: CGSize(width: 1_366, height: 1_024)
        )
        let policy = MirageMedia.MiragePresentationPolicy(
            kind: .desktop,
            request: request,
            prefersPrimaryFocus: false
        )

        let decodedKind = try JSONDecoder().decode(
            MirageMedia.MirageStreamKind.self,
            from: try JSONEncoder().encode(MirageMedia.MirageStreamKind.custom)
        )
        let decodedPolicy = try JSONDecoder().decode(
            MirageMedia.MiragePresentationPolicy.self,
            from: try JSONEncoder().encode(policy)
        )

        #expect(MirageMedia.StreamPresentationKind.allCases.map(\.rawValue) == ["appWindow", "desktop", "custom"])
        #expect(decodedKind == .custom)
        #expect(decodedPolicy == policy)
        #expect(decodedPolicy.request?.requestedSize == CGSize(width: 1_366, height: 1_024))
        #expect(!decodedPolicy.prefersPrimaryFocus)
    }

    @Test("Audio configurations normalize compressed budgets")
    func audioConfigurationsNormalizeCompressedBudgets() throws {
        let lossless = MirageMedia.MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .lossless,
            compressedBitrateBps: 96_000,
            compressedBitrateCeilingBps: 192_000,
            adaptiveCompressionEnabled: true
        )
        let stereo = MirageMedia.MirageAudioConfiguration(
            enabled: true,
            channelLayout: .stereo,
            quality: .high,
            compressedBitrateBps: 16_000,
            compressedBitrateCeilingBps: 48_000,
            adaptiveCompressionEnabled: true
        )

        let encoded = try JSONEncoder().encode(stereo)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageAudioConfiguration.self, from: encoded)

        #expect(MirageMedia.MirageAudioChannelLayout.surround51.channelCount == 6)
        #expect(MirageMedia.MirageAudioQuality.high.defaultCompressedBitrateBps(for: .stereo) == 192_000)
        #expect(MirageMedia.MirageAudioCodec.aacLC.rawValue == 1)
        #expect(lossless.compressedBitrateBps == nil)
        #expect(!lossless.adaptiveCompressionEnabled)
        #expect(stereo.compressedBitrateBps == 64_000)
        #expect(stereo.compressedBitrateCeilingBps == 64_000)
        #expect(decoded == stereo)
    }

    @Test("Video descriptors keep color depth and codec contracts")
    func videoDescriptorsKeepColorDepthAndCodecContracts() {
        let descriptor = MirageMedia.MirageColorDepthDescriptor(
            colorDepth: .pro,
            bitDepth: .tenBit,
            colorSpace: .displayP3,
            capturePixelFormats: [.p010, .bgr10a2]
        )

        #expect(MirageMedia.MirageStreamColorDepth.orderedCases == [.standard, .pro, .ultra])
        #expect(MirageMedia.MirageStreamColorDepth.pro.nextLowerFallback == .standard)
        #expect(MirageMedia.MirageStreamColorDepth.pro.nextHigherRestore == .ultra)
        #expect(MirageMedia.MirageVideoCodec.hevc.rawValue == "hvc1")
        #expect(MirageMedia.MirageUpscalingMode.spatial.displayName == "Spatial")
        #expect(MirageMedia.MirageVideoBitDepth.tenBit.displayName == "10-bit")
        #expect(MirageMedia.MirageStreamChromaSampling.yuv444.rawValue == "4:4:4")
        #expect(MirageMedia.MirageColorSpace.displayP3.displayName == "Display P3")
        #expect(MirageMedia.MiragePixelFormat.p010.displayName == "10-bit (P010)")
        #expect(descriptor.primaryPixelFormat == .p010)
    }

    @Test("Codec low-power preferences resolve local policy")
    func codecLowPowerPreferencesResolveLocalPolicy() {
        #expect(
            MirageMedia.MirageCodecLowPowerModePreference.availableOptions(supportsBatteryPolicy: true) == [.auto, .on, .onlyOnBattery]
        )
        #expect(
            MirageMedia.MirageCodecLowPowerModePreference.availableOptions(supportsBatteryPolicy: false) == [.auto, .on]
        )
        #expect(MirageMedia.MirageCodecLowPowerModePreference.onlyOnBattery.resolvedForBatteryPolicySupport(false) == .auto)
        #expect(MirageMedia.MirageCodecLowPowerModePreference.auto.resolvesToLowPowerMode(isSystemLowPowerModeEnabled: true, isOnBattery: nil))
        #expect(MirageMedia.MirageCodecLowPowerModePreference.on.resolvesToLowPowerMode(isSystemLowPowerModeEnabled: false, isOnBattery: false))
        #expect(
            MirageMedia.MirageCodecLowPowerModePreference.onlyOnBattery.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: false,
                isOnBattery: true
            )
        )
        #expect(MirageMedia.MirageCodecLowPowerModePreference.onlyOnBattery.displayName == "On Battery")
    }

    @Test("Display P3 coverage status keeps warning semantics")
    func displayP3CoverageStatusKeepsWarningSemantics() {
        #expect(MirageMedia.MirageDisplayP3CoverageStatus.strictCanonical.displayName == "Display P3")
        #expect(!MirageMedia.MirageDisplayP3CoverageStatus.strictCanonical.requiresCanonicalCoverageWarning)
        #expect(!MirageMedia.MirageDisplayP3CoverageStatus.wideGamutEquivalent.requiresCanonicalCoverageWarning)
        #expect(MirageMedia.MirageDisplayP3CoverageStatus.sRGBFallback.requiresCanonicalCoverageWarning)
        #expect(MirageMedia.MirageDisplayP3CoverageStatus.unresolved.requiresCanonicalCoverageWarning)
    }

    @Test("Encoder rate-control strategies keep stable wire names")
    func encoderRateControlStrategiesKeepStableWireNames() throws {
        let encoded = try JSONEncoder().encode(MirageMedia.MirageEncoderRateControlStrategy.averageBitRateDataRateLimits)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageEncoderRateControlStrategy.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"averageBitRateDataRateLimits\"")
        #expect(decoded == .averageBitRateDataRateLimits)
        #expect(MirageMedia.MirageEncoderRateControlStrategy.none.rawValue == "none")
    }

    @Test("Stream latency modes preserve labels and Codable names")
    func streamLatencyModesPreserveLabelsAndCodableNames() throws {
        let encoded = try JSONEncoder().encode(MirageMedia.MirageStreamLatencyMode.balanced)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageStreamLatencyMode.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"balanced\"")
        #expect(decoded == .balanced)
        #expect(MirageMedia.MirageStreamLatencyMode.lowestLatency.displayName == "Most Responsive")
        #expect(MirageMedia.MirageStreamLatencyMode.smoothest.detailDescription.contains("steady visual cadence"))
    }

    @Test("Stream cadence targets clamp FPS and playout delay")
    func streamCadenceTargetsClampFPSAndPlayoutDelay() {
        let target = MirageMedia.MirageStreamCadenceTarget(
            sourceFPS: 500,
            displayFPS: 0,
            latencyMode: .smoothest,
            playoutDelayFrames: 99
        )

        #expect(target.sourceFPS == 240)
        #expect(target.displayFPS == 1)
        #expect(target.latencyMode == .smoothest)
        #expect(target.playoutDelayFrames == MirageMedia.MirageStreamCadenceTarget.maximumPlayoutDelayFrames)
        #expect(MirageMedia.MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .balanced) == 2)
        #expect(MirageMedia.MirageStreamCadenceTarget(sourceFPS: 60).sourceFrameBudgetMs == 1_000.0 / 60.0)
    }

    @Test("Interaction cadence exposes 120 Hz timing constants")
    func interactionCadenceExposes120HzTimingConstants() {
        #expect(MirageMedia.MirageInteractionCadence.targetFPS120 == 120)
        #expect(MirageMedia.MirageInteractionCadence.frameInterval120Nanoseconds == 8_333_333)
        #expect(MirageMedia.MirageInteractionCadence.frameInterval120Seconds == 1.0 / 120.0)
        #expect(MirageMedia.MirageInteractionCadence.frameInterval120Duration == .nanoseconds(8_333_333))
    }

    @Test("Media path profile classifies proximity and overlay paths")
    func mediaPathProfileClassifiesProximityAndOverlayPaths() {
        #expect(MirageMedia.MirageMediaPathProfile.classify(pathKind: .awdl, interfaceNames: ["awdl0"]) == .awdlRadio)
        #expect(MirageMedia.MirageMediaPathProfile.classify(pathKind: .awdl, interfaceNames: ["anpi0"]) == .proximityWiredLike)
        #expect(MirageMedia.MirageMediaPathProfile.classify(pathKind: .wifi, interfaceNames: ["en0"], usesWiFi: true) == .localWiFi)
        #expect(MirageMedia.MirageMediaPathProfile.classify(pathKind: .vpn, interfaceNames: ["utun4"]) == .vpnOrOverlay)
        #expect(
            MirageMedia.MirageMediaPathProfile.resolveRealtimeProfile(
                pathKind: .awdl,
                mediaPathProfile: .proximityWiredLike,
                interfaceNames: ["awdl0"]
            ) == .awdlRadio
        )
    }

    @Test("Media send profiles keep stable wire names")
    func mediaSendProfilesKeepStableWireNames() throws {
        #expect(MirageMedia.MirageMediaSendProfile.allCases.map(\.rawValue) == [
            "interactiveMedia",
            "proximityInteractiveMedia",
            "proximityRealtimeDisplay",
            "proximityRealtimeDisplaySingleLane",
            "interactiveAudio",
            "proximityInteractiveAudio",
            "priorityInputRealtime",
            "priorityInputRealtimeSequenced",
            "priorityInputContinuous",
            "priorityInputProtected",
            "throughputProbe",
        ])

        let encoded = try JSONEncoder().encode(MirageMedia.MirageMediaSendProfile.proximityRealtimeDisplay)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageMediaSendProfile.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"proximityRealtimeDisplay\"")
        #expect(decoded == .proximityRealtimeDisplay)
    }
}
