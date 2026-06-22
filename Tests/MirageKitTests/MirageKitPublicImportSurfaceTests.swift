//
//  MirageKitPublicImportSurfaceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import CoreGraphics
import CryptoKit
import Loom
import LoomCloudKit
import MirageKit
import Foundation
import Testing
import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire

@Suite("MirageKit Public Import Surface")
struct MirageKitPublicImportSurfaceTests {
    @Test("Owner module imports expose core public value models")
    func ownerModuleImportsExposeCorePublicValueModels() throws {
        let classification = MirageDiagnostics.MirageDiagnosticsEventClassification(
            disposition: .capture,
            issueKind: "test",
            failureStage: "compile",
            recoveryOutcome: "none"
        )
        #expect(classification.sentryTags["mirage_issue_kind"] == "test")
        let diagnosticsEvent = MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot(
            category: "client",
            severity: .error,
            message: "Desktop stream start timed out after 30s"
        )
        let diagnosticsPolicyClassification = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: diagnosticsEvent
        )
        #expect(diagnosticsPolicyClassification.issueKind == "desktop-startup-failure")
        #expect(!MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.firstFramePresentationFailureTerminalMessage.isEmpty)

        let streamID: StreamID = 42
        let presentationID = StreamPresentationID()
        let streamSessionID = StreamSessionID()
        let streamKind: MirageMedia.MirageStreamKind = .desktop
        let presentationRequest = MirageMedia.StreamPresentationRequest(
            id: presentationID,
            kind: .desktop,
            requestedSize: CGSize(width: 1_366, height: 1_024)
        )
        let presentationPolicy = MirageMedia.MiragePresentationPolicy(
            kind: .desktop,
            request: presentationRequest,
            prefersPrimaryFocus: false
        )
        let sessionSnapshot = MirageDiagnostics.StreamSessionSnapshot(
            id: streamSessionID,
            kind: streamKind,
            streamID: streamID,
            mediaStreamID: 43,
            presentationIDs: [presentationID]
        )
        let presentationSnapshot = MirageDiagnostics.StreamPresentationSnapshot(
            id: presentationID,
            kind: presentationPolicy.kind,
            sessionID: sessionSnapshot.id,
            streamID: sessionSnapshot.streamID,
            mediaStreamID: sessionSnapshot.mediaStreamID
        )
        let peerDeviceID = try #require(UUID(uuidString: "70000000-0000-0000-0000-000000000001"))
        let peerID = MiragePeerID(
            deviceID: peerDeviceID,
            appID: "com.example.MirageHost"
        )
        let authenticatedPeer = MirageAuthenticatedPeerIdentity(
            peerID: peerID,
            displayName: "Studio Host",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true
        )
        let loomPeerIdentity = LoomPeerIdentity(
            deviceID: peerDeviceID,
            name: "Studio Host",
            deviceType: .mac,
            iCloudUserID: "icloud-user",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true,
            endpoint: "studio.local"
        )
        let loomProjectedPeer = MirageAuthenticatedPeerIdentity(loomPeerIdentity: loomPeerIdentity)
        #expect(loomProjectedPeer == MirageAuthenticatedPeerIdentity(
            deviceID: peerDeviceID,
            displayName: "Studio Host",
            deviceType: .mac,
            iCloudUserID: "icloud-user",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true,
            endpointDescription: "studio.local"
        ))
        let trustEvaluation = MirageTrustEvaluationSnapshot(
            decision: .trusted,
            shouldShowAutoTrustNotice: false
        )
        let rejection = MirageCore.MirageConnectionRejection(
            reason: .protocolVersionMismatch,
            hostProtocolVersion: 9,
            clientProtocolVersion: 8
        )
        let mediaStrategy: MirageMediaStrategy = .fullFrameHEVC
        let audioConfiguration: MirageMedia.MirageAudioConfiguration = .default
        let videoCodec: MirageMedia.MirageVideoCodec = .hevc
        let colorDepth: MirageMedia.MirageStreamColorDepth = .pro
        let upscalingMode: MirageMedia.MirageUpscalingMode = .spatial
        let lowPowerPreference: MirageMedia.MirageCodecLowPowerModePreference = .onlyOnBattery
        let p3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus = .strictCanonical
        let latencyMode: MirageMedia.MirageStreamLatencyMode = .balanced
        let topology = MirageMediaTopology.singleUnit(
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            codec: .hevc
        )
        let packetizerInput = MiragePacketizerInput(
            unit: MirageEncodedMediaUnit(
                streamID: 42,
                topologyID: topology.id,
                mediaUnitID: .primary,
                unitFrameNumber: 1,
                presentationTime: MiragePresentationTime(seconds: 0),
                dependency: .keyframe,
                payload: Data([0x01])
            ),
            maximumPayloadBytes: 1
        )
        let capabilities = MirageRuntimeCapabilities.fullFrameBaseline(codecs: [.hevc])
        let connectivityPolicy = MirageConnectivity.MirageConnectivityPolicy()
        let hostSessionAvailability: MirageWire.MirageHostSessionAvailability = .credentialsRequired
        let actionPreferences = MirageInput.MirageActionPreferences(actions: [.missionControl])
        let cursorType: MirageWire.MirageCursorType = .pointingHand
        let streamOptionsDisplayMode: MirageWire.MirageStreamOptionsDisplayMode = .hostMenuBar
        let desktopCursorLockMode: MirageWire.MirageDesktopCursorLockMode = .secondaryOnly
        let desktopCursorSource: MirageWire.MirageDesktopCursorSource = .host
        let desktopStreamStopReason: MirageWire.DesktopStreamStopReason = .hostShutdown
        let startupStreamKind: MirageWire.MirageStartupStreamKind = .desktop
        let windowApplication = MirageMedia.MirageApplication(
            id: 501,
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        let window = MirageMedia.MirageWindow(
            id: 9_001,
            title: "",
            application: windowApplication,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isOnScreen: true,
            windowLayer: 0
        )
        let readyContract = MirageWire.StreamReadyDesktopGeometryContract(
            contractID: UUID(),
            sceneIdentity: "scene-main",
            logicalWidth: 1_376,
            logicalHeight: 1_032,
            displayPixelWidth: 2_752,
            displayPixelHeight: 2_064,
            encodedPixelWidth: 2_752,
            encodedPixelHeight: 2_064,
            refreshTargetHz: 0
        )
        let desktopCursorPresentation = MirageWire.MirageDesktopCursorPresentation(
            source: desktopCursorSource,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )
        let streamRuntimeTier: MirageWire.MirageStreamRuntimeTier = .activeLive
        let streamPolicy = MirageWire.MirageStreamPolicy(
            streamID: 43,
            tier: streamRuntimeTier,
            targetFPS: 200,
            targetBitrateBps: 80_000_000
        )
        let streamPolicyUpdate = MirageWire.StreamPolicyUpdateMessage(epoch: 2, policies: [streamPolicy])
        let customDescriptor = MirageMedia.MirageCustomStreamDescriptor(
            kind: "dev.example.custom.v1",
            displayName: "Example Custom Stream",
            defaultWidth: 1_024,
            defaultHeight: 768
        )
        let customStarted = MirageWire.MirageCustomStreamStartedMessage(
            startupRequestID: UUID(),
            streamID: 44,
            descriptor: customDescriptor,
            width: 1_024,
            height: 768,
            frameRate: 60,
            codec: videoCodec,
            startupAttemptID: nil,
            dimensionToken: nil,
            acceptedMediaMaxPacketSize: nil
        )
        let customStopped = MirageWire.MirageCustomStreamStoppedMessage(streamID: 44, reason: .sourceStopped)
        let appAtlasRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_001,
            x: 0,
            y: 0,
            width: 1_440,
            height: 900
        )
        let appAtlasLayout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 43,
            layoutEpoch: 2,
            width: 1_440,
            height: 900,
            regions: [appAtlasRegion]
        )
        let appAtlasMediaUpdate = MirageWire.AppAtlasMediaUpdateMessage(
            mediaStreamID: 43,
            width: 1_440,
            height: 900,
            codec: videoCodec,
            frameRate: 120,
            layoutEpoch: 2,
            layout: appAtlasLayout,
            startupAttemptID: UUID()
        )
        let appStreamStarted = MirageWire.AppStreamStartedMessage(
            appSessionID: UUID(),
            startupRequestID: UUID(),
            bundleIdentifier: "com.example.Editor",
            appName: "Editor",
            windows: [
                MirageWire.AppStreamStartedMessage.AppStreamWindow(
                    streamID: 143,
                    mediaStreamID: 43,
                    windowID: 9_001,
                    title: "Editor",
                    width: 1_440,
                    height: 900,
                    isResizable: true,
                    atlasRegion: appAtlasRegion
                ),
            ],
            atlasLayouts: [appAtlasLayout]
        )
        let appWindowFailureCode: MirageWire.WindowStreamFailedMessage.FailureCode = .windowNotFound
        let appWindowResizeOutcome: MirageWire.MirageAppWindowResizeResultOutcome = .applied
        let menuShortcut = MirageWire.MirageKeyboardShortcut(key: "n", modifiers: [.command, .shift])
        let menuBar = MirageWire.MirageMenuBar(
            bundleIdentifier: "com.example.Editor",
            menus: [
                MirageWire.MirageMenu(
                    title: "File",
                    items: [
                        MirageWire.MirageMenuItem(
                            title: "New",
                            keyboardShortcut: menuShortcut,
                            actionPath: [0, 0]
                        ),
                    ],
                    menuIndex: 0
                ),
            ],
            version: 1
        )
        let supportEntry = MirageDiagnostics.MirageLogArchiveEntry(name: "DiagnosticsSummary.txt", text: "summary")
        let logCategory: MirageDiagnostics.MirageLogCategory = .bootstrapHandoff
        let decisionTrace = MirageDiagnostics.MirageRecipeDecisionTrace(decisions: [
            MirageDiagnostics.MirageRecipeDecision(
                key: "mediaStrategy",
                value: MirageMediaStrategy.fullFrameHEVC.rawValue,
                reason: "compile surface"
            ),
        ])
        #expect(streamID == 42)
        #expect(presentationID.uuidString.count == 36)
        #expect(streamKind == .desktop)
        #expect(presentationRequest.requestedSize == CGSize(width: 1_366, height: 1_024))
        #expect(!presentationPolicy.prefersPrimaryFocus)
        #expect(sessionSnapshot.kind == .desktop)
        #expect(presentationSnapshot.mediaStreamID == 43)
        #expect(peerID.appID == "com.example.MirageHost")
        #expect(authenticatedPeer.hasAuthenticatedIdentityKey)
        #expect(trustEvaluation.authorizesBusyHostTakeover)
        #expect(MirageWireProtocol.currentDiscoveryVersion == MirageKit.discoveryProtocolVersion)
        #expect(MirageWireProtocol.currentControlVersion == MirageKit.controlProtocolVersion)
        #expect(MirageWireProtocol.currentMediaPacketVersion == MirageKit.mediaPacketProtocolVersion)
        #expect(mediaStrategy == .fullFrameHEVC)
        #expect(audioConfiguration.channelLayout == .stereo)
        #expect(videoCodec.rawValue == "hvc1")
        #expect(colorDepth.nextLowerFallback == .standard)
        #expect(upscalingMode.displayName == "Spatial")
        #expect(lowPowerPreference.displayName == "On Battery")
        #expect(p3CoverageStatus.displayName == "Display P3")
        #expect(latencyMode.displayName == "Balanced")
        #expect(topology.representsSingleUnitFullFrame)
        #expect(packetizerInput.payloadByteCount == 1)
        #expect(capabilities.protocolVersions == [.currentControl])
        #expect(capabilities.mediaPacketFamilies == [.fixedHeaderFullFrame])
        #expect(capabilities.supportsControlFeature(.sessionBootstrap))
        #expect(capabilities.supportsMediaTopology(.singleUnit))
        #expect(MirageMedia.MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: 96_000_000) == 96_000_000)
        #expect(MirageKit.serviceType == MirageConnectivity.MirageNetworkConfiguration.default.serviceType)
        #expect(connectivityPolicy.mediaSendProfile == .interactiveMedia)
        #expect(hostSessionAvailability.requiresCredentials)
        #expect(cursorType.rawValue == 5)
        #expect(streamOptionsDisplayMode.displayName == "Host Menu Bar")
        #expect(desktopCursorLockMode.displayName == "Secondary Only")
        #expect(desktopCursorLockMode.footerDescription.contains("Secondary displays"))
        #expect(desktopCursorLockMode.locksClientCursor(for: .secondary))
        #expect(desktopCursorLockMode.locksClientCursor(for: .unified) == false)
        #expect(desktopStreamStopReason.rawValue == "hostShutdown")
        #expect(startupStreamKind.rawValue == "desktop")
        #expect(window.displayName == "Editor")
        #expect(window.withTabCount(2).tabCount == 2)
        #expect(readyContract.refreshTargetHz == 1)
        #expect(desktopCursorSource.displayName == "Host")
        #expect(desktopCursorSource.footerDescription.contains("real Mac cursor"))
        #expect(desktopCursorPresentation.capturesHostCursor)
        #expect(desktopCursorPresentation.lockClientCursorPreference(for: .host))
        #expect(desktopCursorPresentation.canToggleLockClientCursor(for: .unified))
        #expect(desktopCursorPresentation.locksClientCursor(for: .unified))
        #expect(streamRuntimeTier.rawValue == "activeLive")
        #expect(streamPolicy.targetFPS == 120)
        #expect(streamPolicyUpdate.policies.first?.streamID == 43)
        #expect(customDescriptor.defaultFrameRate == 60)
        #expect(customStarted.descriptor == customDescriptor)
        #expect(customStopped.reason.rawValue == "sourceStopped")
        #expect(appAtlasMediaUpdate.layout == appAtlasLayout)
        #expect(appStreamStarted.windows.first?.mediaStreamID == 43)
        #expect(appWindowFailureCode.rawValue == "windowNotFound")
        #expect(appWindowResizeOutcome.rawValue == "applied")
        #expect(menuShortcut.displayString == "\u{21E7}\u{2318}N")
        #expect(menuBar.menus.first?.items.first?.keyboardShortcut == menuShortcut)
        #expect(
            connectivityPolicy.priorityInputPolicy.decision(
                selectedTransport: .udp,
                receiveSemantics: "independent-reliable-unreliable"
            ).isAvailable
        )
        #expect(rejection.isTerminal)
        #expect(MirageCore.MirageError.connectionRejected(rejection).errorDescription?.contains("incompatible") == true)
        #expect(actionPreferences.action(withID: MirageInput.MirageAction.missionControlID)?.id == MirageInput.MirageAction.missionControlID)
        #expect(supportEntry.data == Data("summary".utf8))
        #expect(logCategory.rawValue == "bootstrap_handoff")
        #expect(decisionTrace.decisions.first?.key == "mediaStrategy")

        let input = MirageInput.MirageInputEvent.mouseDown(
            MirageInput.MirageMouseEvent(location: CGPoint(x: 0.25, y: 0.75))
        )
        guard case let .mouseDown(mouseEvent) = input else {
            Issue.record("Expected mouseDown input event")
            return
        }
        #expect(mouseEvent.button == .left)

        let systemAction = try #require(MirageInput.MirageAction.spaceLeft.hostSystemActionRequest)
        #expect(systemAction.action == .spaceLeft)
    }

    @Test("Owner surface tests import Foundation explicitly")
    func ownerSurfaceTestsImportFoundationExplicitly() {
        let date: Date = Date(timeIntervalSinceReferenceDate: 0)

        #expect(date.timeIntervalSinceReferenceDate == 0)
    }

    @Test("MirageKit Loom integration APIs require explicit Loom imports")
    func mirageKitLoomIntegrationAPIsRequireExplicitLoomImports() {
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: Int(MirageKit.discoveryProtocolVersion),
            deviceID: UUID(),
            identityKeyID: "identity-key",
            deviceType: .mac,
            metadata: ["mirage.test": "1"]
        )
        let cloudConfiguration: LoomCloudKitConfiguration = MirageKit.makeCloudKitConfiguration(
            containerIdentifier: "iCloud.com.example.Mirage"
        )
        let mirageCloudConfiguration = MirageKit.makeMirageCloudKitIdentityConfiguration(
            containerIdentifier: "iCloud.com.example.Mirage"
        )
        let loomIdentity = LoomAccountIdentity(
            keyID: LoomIdentityManager.keyID(for: Data([0x04, 0x01, 0x02])),
            publicKey: Data([0x04, 0x01, 0x02])
        )
        let localIdentitySnapshot = MirageLocalIdentitySnapshot(loomIdentity: loomIdentity)
        let validPublicKey = P256.Signing.PrivateKey().publicKey.x963Representation

        #expect(advertisement.protocolVersion == Int(MirageKit.discoveryProtocolVersion))
        #expect(advertisement.deviceType == .mac)
        #expect(advertisement.identityKeyID == "identity-key")
        #expect(advertisement.metadata["mirage.test"] == "1")
        #expect(cloudConfiguration.containerIdentifier == "iCloud.com.example.Mirage")
        #expect(mirageCloudConfiguration.containerIdentifier == cloudConfiguration.containerIdentifier)
        #expect(mirageCloudConfiguration.deviceRecordType == cloudConfiguration.deviceRecordType)
        #expect(mirageCloudConfiguration.peerRecordType == cloudConfiguration.peerRecordType)
        #expect(mirageCloudConfiguration.peerZoneName == cloudConfiguration.peerZoneName)
        #expect(
            mirageCloudConfiguration.participantIdentityRecordType ==
                cloudConfiguration.participantIdentityRecordType
        )
        #expect(cloudConfiguration.deviceRecordType == "MirageDevice")
        #expect(cloudConfiguration.peerRecordType == "MiragePeer")
        #expect(cloudConfiguration.peerZoneName == "MiragePeerZone")
        #expect(cloudConfiguration.participantIdentityRecordType == "MirageParticipantIdentity")
        #expect(cloudConfiguration.deviceIDKey == MirageIdentityConfiguration.sharedDeviceIDKey)
        #expect(cloudConfiguration.deviceIDSuiteName == MirageIdentityConfiguration.sharedDeviceIDSuiteName)
        #expect(mirageCloudConfiguration.sharedDeviceIDConfiguration == MirageKit.sharedDeviceIDConfiguration)
        #expect(MirageKit.identityService == MirageIdentityConfiguration.identityService)
        #expect(localIdentitySnapshot.keyID == loomIdentity.keyID)
        #expect(localIdentitySnapshot.publicKey == loomIdentity.publicKey)
        #expect(localIdentitySnapshot.hasPublicKey)
        #expect(MirageIdentityKeyID.keyID(for: validPublicKey) == LoomIdentityManager.keyID(for: validPublicKey))
        #expect(
            MirageIdentityKeyID.keyID(for: Data([0x01, 0x02, 0x03])) ==
                LoomIdentityManager.keyID(for: Data([0x01, 0x02, 0x03]))
        )
    }

    @Test("MirageKit import does not re-export Loom symbols")
    func mirageKitImportDoesNotReExportLoomSymbols() throws {
        let packageRoot = packageRootURL()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MirageKitNoLoomReexport-\(UUID().uuidString)")
        let sourceRoot = tempRoot.appendingPathComponent("Sources/Probe")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "MirageKitNoLoomReexportProbe",
            platforms: [
                .macOS("26.0"),
                .iOS("26.0"),
                .visionOS("26.0"),
            ],
            dependencies: [
                .package(path: \(swiftStringLiteral(packageRoot.path))),
            ],
            targets: [
                .executableTarget(
                    name: "Probe",
                    dependencies: [
                        .product(name: "MirageKit", package: "MirageKit"),
                    ]
                ),
            ]
        )
        """
        let probe = """
        import MirageKit

        let advertisementType = LoomPeerAdvertisement.self
        let cloudConfigurationType = LoomCloudKitConfiguration.self
        _ = advertisementType
        _ = cloudConfigurationType
        """
        try manifest.write(
            to: tempRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try probe.write(
            to: sourceRoot.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try runProcess(
            executablePath: "/usr/bin/swift",
            arguments: [
                "build",
                "--package-path",
                tempRoot.path,
                "--scratch-path",
                tempRoot.appendingPathComponent(".build").path,
            ],
            currentDirectory: packageRoot
        )
        let output = result.standardOutput + result.standardError

        #expect(result.terminationStatus != 0)
        #expect(output.contains("LoomPeerAdvertisement"))
        #expect(output.contains("LoomCloudKitConfiguration"))
    }
}

private func packageRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func swiftStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func runProcess(
    executablePath: String,
    arguments: [String],
    currentDirectory: URL
) throws -> (terminationStatus: Int32, standardOutput: String, standardError: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return (
        process.terminationStatus,
        String(data: outputData, encoding: .utf8) ?? "",
        String(data: errorData, encoding: .utf8) ?? ""
    )
}
