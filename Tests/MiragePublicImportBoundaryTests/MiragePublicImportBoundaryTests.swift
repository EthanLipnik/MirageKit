//
//  MiragePublicImportBoundaryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import CryptoKit
import Foundation
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Testing

@Suite("Mirage Public Import Boundary")
struct MiragePublicImportBoundaryTests {
    @Test("App-facing leaf imports compile without Loom")
    func appFacingLeafImportsCompileWithoutLoom() throws {
        let streamID: StreamID = 42
        let streamKind: MirageMedia.MirageStreamKind = .desktop
        let streamSessionID = try #require(UUID(uuidString: "71000000-0000-0000-0000-000000000101"))
        let presentationID = try #require(UUID(uuidString: "71000000-0000-0000-0000-000000000102"))
        let peerDeviceID = try #require(UUID(uuidString: "71000000-0000-0000-0000-000000000001"))
        let peerID = MiragePeerID(deviceID: peerDeviceID, appID: "com.example.MirageHost")
        let localPublicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let localIdentity = MirageLocalIdentitySnapshot(
            keyID: MirageIdentityKeyID.keyID(for: localPublicKey),
            publicKey: localPublicKey
        )
        let bootstrapPeer = MirageBootstrapAuthenticatedPeer(
            keyID: localIdentity.keyID,
            publicKey: localPublicKey,
            endpointDescription: "127.0.0.1"
        )
        let sharedDeviceConfiguration = MirageIdentityConfiguration.sharedDeviceIDConfiguration
        let cloudKitIdentityConfiguration = MirageIdentityConfiguration.cloudKitIdentityConfiguration(
            containerIdentifier: "iCloud.com.example.Mirage"
        )
        let authenticatedPeer = MirageAuthenticatedPeerIdentity(
            peerID: peerID,
            displayName: "Studio Host",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true
        )
        let trustEvaluation = MirageTrustEvaluationSnapshot(
            decision: .trusted,
            shouldShowAutoTrustNotice: false
        )
        let presentationRequest = MirageMedia.StreamPresentationRequest(
            id: presentationID,
            kind: .desktop,
            ownerID: peerDeviceID,
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
            ownerID: peerDeviceID,
            sessionID: sessionSnapshot.id,
            streamID: sessionSnapshot.streamID,
            mediaStreamID: sessionSnapshot.mediaStreamID
        )
        let classification = MirageDiagnostics.MirageDiagnosticsEventClassification(
            disposition: .breadcrumbOnly,
            issueKind: "compile-boundary",
            failureStage: "import",
            recoveryOutcome: "none"
        )
        let diagnosticsEvent = MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot(
            category: "client",
            severity: .error,
            message: "Desktop stream start timed out after 30s"
        )
        let diagnosticsPolicyClassification = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: diagnosticsEvent
        )
        let foregroundHealth = MirageForegroundStreamHealthSnapshot(
            streamID: streamID,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 1,
            submittedSequence: 2,
            isAwaitingKeyframe: false
        )
        let inputEvent = MirageInput.MirageInputEvent.mouseMoved(
            MirageInput.MirageMouseEvent(location: CGPoint(x: 0.25, y: 0.75))
        )
        let topology = MirageMediaTopology.singleUnit(
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            codec: .hevc
        )
        let capabilities = MirageRuntimeCapabilities.fullFrameBaseline(codecs: [.hevc])
        let hostSessionAvailability: MirageWire.MirageHostSessionAvailability = .credentialsAndUserIdentifierRequired
        let cursorType: MirageWire.MirageCursorType = .resizeNWSE
        let streamOptionsDisplayMode: MirageWire.MirageStreamOptionsDisplayMode = .hostMenuBar
        let desktopStreamStopReason: MirageWire.DesktopStreamStopReason = .appStreamStarted
        let startupStreamKind: MirageWire.MirageStartupStreamKind = .appAtlas
        let windowApplication = MirageMedia.MirageApplication(
            id: 501,
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        let window = MirageMedia.MirageWindow(
            id: 9_001,
            title: "Editor",
            application: windowApplication,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isOnScreen: true,
            windowLayer: 0
        )
        let readyContract = MirageWire.StreamReadyDesktopGeometryContract(
            contractID: UUID(),
            sceneIdentity: "",
            logicalWidth: 1_376,
            logicalHeight: 1_032,
            displayPixelWidth: 2_752,
            displayPixelHeight: 2_064,
            encodedPixelWidth: 2_752,
            encodedPixelHeight: 2_064,
            refreshTargetHz: 0
        )
        let desktopCursorPresentation = MirageWire.MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )
        let streamRuntimeTier: MirageWire.MirageStreamRuntimeTier = .passiveSnapshot
        let streamPolicy = MirageWire.MirageStreamPolicy(
            streamID: 43,
            tier: streamRuntimeTier,
            targetFPS: 0,
            targetBitrateBps: nil
        )
        let streamPolicyUpdate = MirageWire.StreamPolicyUpdateMessage(epoch: 3, policies: [streamPolicy])
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
            codec: .hevc,
            startupAttemptID: nil,
            dimensionToken: nil,
            acceptedMediaMaxPacketSize: nil
        )
        let customStopped = MirageWire.MirageCustomStreamStoppedMessage(streamID: 44, reason: .hostShutdown)
        let appAtlasRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_001,
            x: 0,
            y: 0,
            width: 1_440,
            height: 900
        )
        let appAtlasLayout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 43,
            layoutEpoch: 3,
            width: 1_440,
            height: 900,
            regions: [appAtlasRegion]
        )
        let appAtlasMediaUpdate = MirageWire.AppAtlasMediaUpdateMessage(
            mediaStreamID: 43,
            width: 1_440,
            height: 900,
            codec: .hevc,
            frameRate: 60,
            layoutEpoch: 3,
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
        let appWindowFailureCode: MirageWire.WindowStreamFailedMessage.FailureCode = .windowPlacementFailed
        let appWindowResizeOutcome: MirageWire.MirageAppWindowResizeResultOutcome = .notResizable
        let menuBar = MirageWire.MirageMenuBar(
            bundleIdentifier: "com.example.Editor",
            menus: [
                MirageWire.MirageMenu(
                    title: "Edit",
                    items: [
                        MirageWire.MirageMenuItem(
                            title: "Copy",
                            keyboardShortcut: MirageWire.MirageKeyboardShortcut(key: "c", modifiers: [.command]),
                            actionPath: [0, 0]
                        ),
                    ],
                    menuIndex: 0
                ),
            ],
            version: 2
        )
        let qualityPlan = MirageDiagnostics.MirageQualityTestPlan(stages: [
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 1,
                probeKind: .transport,
                targetBitrateBps: 80_000_000,
                durationMs: 500
            ),
        ])
        let qualitySummary = MirageDiagnostics.MirageQualityTestSummary(
            testID: UUID(),
            rttMs: 5,
            lossPercent: 0,
            transportHeadroomBps: 80_000_000,
            streamingSafeBitrateBps: 72_000_000,
            targetFrameRate: 120,
            benchmarkWidth: 1920,
            benchmarkHeight: 1080,
            hostEncodeMs: nil,
            clientDecodeMs: nil,
            stageResults: []
        )
        let logCategory: MirageDiagnostics.MirageLogCategory = .bootstrapHandoff
        let decisionTrace = MirageDiagnostics.MirageRecipeDecisionTrace().appending(
            MirageDiagnostics.MirageRecipeDecision(
                key: "mediaStrategy",
                value: "fullFrameHEVC",
                reason: "compile boundary"
            )
        )

        #expect(streamID == 42)
        #expect(streamKind == .desktop)
        #expect(authenticatedPeer.hasAuthenticatedIdentityKey)
        #expect(trustEvaluation.authorizesBusyHostTakeover)
        #expect(localIdentity.hasPublicKey)
        #expect(localIdentity.keyIDMatchesPublicKey)
        #expect(bootstrapPeer.keyIDMatchesPublicKey)
        #expect(sharedDeviceConfiguration.key == MirageIdentityConfiguration.sharedDeviceIDKey)
        #expect(cloudKitIdentityConfiguration.peerZoneName == MirageIdentityConfiguration.cloudKitPeerZoneName)
        #expect(cloudKitIdentityConfiguration.sharedDeviceIDConfiguration == sharedDeviceConfiguration)
        #expect(presentationRequest.requestedSize == CGSize(width: 1_366, height: 1_024))
        #expect(!presentationPolicy.prefersPrimaryFocus)
        #expect(sessionSnapshot.presentationIDs == [presentationID])
        #expect(presentationSnapshot.sessionID == streamSessionID)
        #expect(peerID.deviceID == peerDeviceID)
        #expect(classification.sentryTags["mirage_issue_kind"] == "compile-boundary")
        #expect(diagnosticsPolicyClassification.issueKind == "desktop-startup-failure")
        #expect(foregroundHealth.streamID == streamID)
        guard case let .mouseMoved(mouseEvent) = inputEvent else {
            Issue.record("Expected mouseMoved input event")
            return
        }
        #expect(mouseEvent.location == CGPoint(x: 0.25, y: 0.75))
        #expect(topology.representsSingleUnitFullFrame)
        #expect(capabilities.supportsMediaTopology(.singleUnit))
        #expect(hostSessionAvailability.requiresUserIdentifier)
        #expect(cursorType.rawValue == 22)
        #expect(streamOptionsDisplayMode.rawValue == "hostMenuBar")
        #expect(desktopStreamStopReason.rawValue == "appStreamStarted")
        #expect(startupStreamKind.rawValue == "appAtlas")
        #expect(window.application == windowApplication)
        #expect(window.displayName == "Editor")
        #expect(readyContract.sceneIdentity == nil)
        #expect(readyContract.refreshTargetHz == 1)
        #expect(desktopCursorPresentation.source == .host)
        #expect(desktopCursorPresentation.capturesHostCursor)
        #expect(desktopCursorPresentation.lockClientCursorPreference(for: .host))
        #expect(streamRuntimeTier.rawValue == "passiveSnapshot")
        #expect(streamPolicyUpdate.policies.first?.targetFPS == 1)
        #expect(customDescriptor.kind == "dev.example.custom.v1")
        #expect(customStarted.width == 1_024)
        #expect(customStopped.reason.rawValue == "hostShutdown")
        #expect(appAtlasMediaUpdate.layout == appAtlasLayout)
        #expect(appStreamStarted.windows.first?.streamID == 143)
        #expect(appWindowFailureCode.rawValue == "windowPlacementFailed")
        #expect(appWindowResizeOutcome.rawValue == "notResizable")
        #expect(menuBar.menus.first?.items.first?.keyboardShortcut?.modifiers == [.command])
        #expect(qualityPlan.totalDurationMs == 1_000)
        #expect(qualitySummary.streamingSafeBitrateBps == 72_000_000)
        #expect(logCategory.rawValue == "bootstrap_handoff")
        #expect(decisionTrace.decisions.first?.value == "fullFrameHEVC")
        #expect(MirageWireProtocol.currentControlVersion == MirageWireProtocol.rearchitectureCutoverVersion)
    }

    @MainActor
    @Test("MirageIdentity trust provider compiles without Loom")
    func mirageIdentityTrustProviderCompilesWithoutLoom() async throws {
        let deviceID = try #require(UUID(uuidString: "71000000-0000-0000-0000-000000000004"))
        let peer = MirageAuthenticatedPeerIdentity(
            deviceID: deviceID,
            displayName: "Studio iPad",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true
        )
        let provider = LeafImportTrustProvider(decision: .trusted)

        let evaluation = await provider.evaluateTrustOutcome(for: peer)
        try await provider.grantTrust(to: peer)
        try await provider.revokeTrust(for: peer.peerID)

        #expect(evaluation.authorizesBusyHostTakeover)
        #expect(provider.grantedPeers == [peer])
        #expect(provider.revokedPeerIDs == [peer.peerID])
    }
}

@MainActor
private final class LeafImportTrustProvider: MirageTrustProvider {
    let decision: MirageTrustDecision
    private(set) var grantedPeers: [MirageAuthenticatedPeerIdentity] = []
    private(set) var revokedPeerIDs: [MiragePeerID] = []

    init(decision: MirageTrustDecision) {
        self.decision = decision
    }

    func evaluateTrust(for _: MirageAuthenticatedPeerIdentity) async -> MirageTrustDecision {
        decision
    }

    func grantTrust(to peer: MirageAuthenticatedPeerIdentity) async throws {
        grantedPeers.append(peer)
    }

    func revokeTrust(for peerID: MiragePeerID) async throws {
        revokedPeerIDs.append(peerID)
    }
}
