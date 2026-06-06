//
//  MirageStreamingRecipeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import CoreGraphics
import Foundation
import MirageKit
import Testing
import MirageDiagnostics
import MirageMedia

@Suite("Mirage Streaming Recipe")
struct MirageStreamingRecipeTests {
    @Test("App intent recipe round trips")
    func appIntentRecipeRoundTrips() throws {
        let ownerID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000001"))
        let presentationID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000002"))
        let presentationRequest = MirageMedia.StreamPresentationRequest(
            id: presentationID,
            kind: .appWindow,
            ownerID: ownerID,
            requestedSize: CGSize(width: 1_366, height: 1_024)
        )
        let intent = MirageStreamIntent.app(
            MirageAppStreamIntent(
                bundleIdentifier: "com.example.Editor",
                displayResolution: CGSize(width: 1_366, height: 1_024),
                presentationRequest: presentationRequest
            )
        )
        let recipe = MirageStreamingRecipe(
            intent: intent,
            mediaStrategy: .appAtlas,
            presentationPolicy: MirageMedia.MiragePresentationPolicy(
                kind: .appWindow,
                request: presentationRequest
            ),
            displayResolution: CGSize(width: 1_366, height: 1_024),
            scaleFactor: 2,
            encoderOverrides: MirageEncoderOverrides(
                codec: .hevc,
                bitrate: 80_000_000,
                latencyMode: .lowestLatency
            ),
            audioConfiguration: MirageMedia.MirageAudioConfiguration.default,
            maxConcurrentVisibleWindows: 3,
            sizePreset: .medium,
            decisionTrace: MirageDiagnostics.MirageRecipeDecisionTrace(
                decisions: [
                    MirageDiagnostics.MirageRecipeDecision(
                        key: "mediaStrategy",
                        value: MirageMediaStrategy.appAtlas.rawValue,
                        reason: "Current app streaming behavior"
                    ),
                ]
            )
        )

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(MirageStreamingRecipe.self, from: data)

        #expect(decoded == recipe)
        #expect(decoded.intent.streamKind == .app)
        #expect(decoded.mediaStrategy == .appAtlas)
        #expect(decoded.maxConcurrentVisibleWindows == 3)
    }

    @Test("Desktop intent recipe preserves full frame HEVC strategy")
    func desktopIntentRecipePreservesFullFrameHEVCStrategy() throws {
        let presentationID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000003"))
        let intent = MirageStreamIntent.desktop(
            MirageDesktopStreamIntent(
                mode: .unified,
                cursorPresentation: .simulatedCursor,
                drawableSize: CGSize(width: 1_504, height: 846),
                drawableScaleFactor: 2,
                presentationRequest: MirageMedia.StreamPresentationRequest(
                    id: presentationID,
                    kind: .desktop
                )
            )
        )
        let recipe = MirageStreamingRecipe(
            intent: intent,
            mediaStrategy: .fullFrameHEVC,
            presentationPolicy: MirageMedia.MiragePresentationPolicy(
                kind: .desktop,
                request: MirageMedia.StreamPresentationRequest(
                    id: presentationID,
                    kind: .desktop
                )
            ),
            displayResolution: CGSize(width: 3_008, height: 1_692),
            scaleFactor: 2,
            encoderOverrides: MirageEncoderOverrides(
                codec: .hevc,
                keyFrameInterval: 1_800,
                colorDepth: .pro,
                bitrate: 150_000_000,
                disableResolutionCap: true
            ),
            audioConfiguration: .default,
            useHostResolution: false,
            decisionTrace: MirageDiagnostics.MirageRecipeDecisionTrace().appending(
                MirageDiagnostics.MirageRecipeDecision(
                    key: "mediaStrategy",
                    value: MirageMediaStrategy.fullFrameHEVC.rawValue,
                    reason: "Current desktop streaming behavior"
                )
            )
        )

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(MirageStreamingRecipe.self, from: data)

        #expect(decoded == recipe)
        #expect(decoded.intent.streamKind == .desktop)
        #expect(decoded.mediaStrategy == .fullFrameHEVC)
        #expect(decoded.presentationPolicy.kind == .desktop)
    }

    @Test("Session and presentation snapshots separate media from presentation")
    func snapshotsSeparateMediaFromPresentation() throws {
        let sessionID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000004"))
        let presentationID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000005"))
        let ownerID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000006"))
        let session = MirageDiagnostics.StreamSessionSnapshot(
            id: sessionID,
            kind: .app,
            streamID: 7,
            mediaStreamID: 42,
            appSessionID: sessionID,
            presentationIDs: [presentationID]
        )
        let presentation = MirageDiagnostics.StreamPresentationSnapshot(
            id: presentationID,
            kind: .appWindow,
            ownerID: ownerID,
            sessionID: session.id,
            streamID: session.streamID,
            mediaStreamID: session.mediaStreamID
        )

        #expect(session.streamID != session.mediaStreamID)
        #expect(presentation.sessionID == session.id)

        let decodedSession = try JSONDecoder().decode(
            MirageDiagnostics.StreamSessionSnapshot.self,
            from: try JSONEncoder().encode(session)
        )
        let decodedPresentation = try JSONDecoder().decode(
            MirageDiagnostics.StreamPresentationSnapshot.self,
            from: try JSONEncoder().encode(presentation)
        )

        #expect(decodedSession == session)
        #expect(decodedPresentation == presentation)
    }
}
