//
//  StreamContentRecoveryPresentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/19/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing
import MirageCore
import MirageMedia

@Suite("Stream Content Recovery Presentation", .serialized)
struct StreamContentRecoveryPresentationTests {
    @MainActor
    @Test("Active recovery blur is suppressed while fresh frames are accepted")
    func activeRecoveryBlurIsSuppressedWhileFreshFramesAreAccepted() {
        let activeInitialDeadline = MirageStreamContentView.presentationBlurProgressSuppressionDeadline(
            latestSubmittedTime: 19.8,
            now: 20,
            holdDuration: 0.5
        )
        #expect(abs((activeInitialDeadline ?? 0) - 20.3) < 0.0001)

        let expiredInitialDeadline = MirageStreamContentView.presentationBlurProgressSuppressionDeadline(
            latestSubmittedTime: 19.4,
            now: 20,
            holdDuration: 0.5
        )
        #expect(expiredInitialDeadline == nil)

        let firstFrameAfterEmptyStore = MirageStreamContentView.nextPresentationBlurProgressSuppression(
            baselineSubmissionSequence: 0,
            latestSubmissionSequence: 10,
            now: 20,
            holdDuration: 0.5
        )
        #expect(firstFrameAfterEmptyStore.baselineSubmissionSequence == 10)
        #expect(firstFrameAfterEmptyStore.suppressedUntil == 20.5)

        let noProgress = MirageStreamContentView.nextPresentationBlurProgressSuppression(
            baselineSubmissionSequence: 10,
            latestSubmissionSequence: 10,
            now: 20,
            holdDuration: 0.5
        )
        #expect(noProgress.baselineSubmissionSequence == 10)
        #expect(noProgress.suppressedUntil == nil)

        let freshFrame = MirageStreamContentView.nextPresentationBlurProgressSuppression(
            baselineSubmissionSequence: 10,
            latestSubmissionSequence: 11,
            now: 20,
            holdDuration: 0.5
        )
        #expect(freshFrame.baselineSubmissionSequence == 11)
        #expect(freshFrame.suppressedUntil == 20.5)

        let resetThenFreshFrame = MirageStreamContentView.nextPresentationBlurProgressSuppression(
            baselineSubmissionSequence: 50,
            latestSubmissionSequence: 1,
            now: 20,
            holdDuration: 0.5
        )
        #expect(resetThenFreshFrame.baselineSubmissionSequence == 1)
        #expect(resetThenFreshFrame.suppressedUntil == 20.5)
    }

    @MainActor
    @Test("Recovery blur debounce keeps short media recoveries sharp")
    func recoveryBlurDebounceKeepsShortMediaRecoveriesSharp() {
        #expect(MirageStreamContentView.recoveryBlurDebounceInterval(for: .keyframeRecovery) == 0.30)
        #expect(MirageStreamContentView.recoveryBlurDebounceInterval(for: .hardRecovery) == 0.15)
        #expect(MirageStreamContentView.recoveryBlurDebounceInterval(for: .postResizeAwaitingFirstFrame) == nil)
    }

    @MainActor
    @Test("Post-resize blur clears when the replacement frame is presented")
    func postResizeBlurClearsWhenReplacementFrameIsPresented() throws {
        let store = MirageClientSessionStore()
        let service = MirageClientService()
        let streamID: StreamID = 601
        let sessionID = store.createSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageMedia.MirageWindow(
                id: 60101,
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))
        store.markFirstFramePresented(for: streamID)
        store.setClientRecoveryStatus(for: streamID, status: .postResizeAwaitingFirstFrame)

        let view = MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service,
            isDesktopStream: true
        )

        store.beginPostResizeTransition(for: streamID)
        #expect(view.presentationBlurRadius == 24)

        store.markFirstFramePresented(for: streamID)
        #expect(session.clientRecoveryStatus == .postResizeAwaitingFirstFrame)
        #expect(!store.isAwaitingPostResizeFirstFrame(for: streamID))
        #expect(view.presentationBlurRadius == 0)
    }

    @Test("Desktop resize blur is not suppressed by fresh frame progress")
    @MainActor
    func desktopResizeBlurIsNotSuppressedByFreshFrameProgress() {
        #expect(
            MirageStreamContentView.resolvedPresentationBlurRadius(
                resizeRadius: 20,
                recoveryRadius: 0,
                suppressesRecoveryBlurForRecentProgress: true
            ) == 20
        )
        #expect(
            MirageStreamContentView.resolvedPresentationBlurRadius(
                resizeRadius: 24,
                recoveryRadius: 16,
                suppressesRecoveryBlurForRecentProgress: true
            ) == 24
        )
        #expect(
            MirageStreamContentView.resolvedPresentationBlurRadius(
                resizeRadius: 0,
                recoveryRadius: 16,
                suppressesRecoveryBlurForRecentProgress: true
            ) == 0
        )
        #expect(
            MirageStreamContentView.resolvedPresentationBlurRadius(
                resizeRadius: 0,
                recoveryRadius: 16,
                suppressesRecoveryBlurForRecentProgress: false
            ) == 16
        )
    }

    #if os(iOS) || os(visionOS)
    @MainActor
    @Test("Direct touch suppresses simulated desktop cursor overlay")
    func directTouchSuppressesSimulatedDesktopCursorOverlay() throws {
        let view = try makeDesktopContentView(
            cursorPresentation: .simulatedCursor,
            directTouchInputMode: .normal
        )

        #expect(!view.syntheticCursorEnabled)
        #expect(view.desktopLocalCursorHidden)
    }

    @MainActor
    @Test("Direct touch preserves client desktop cursor presentation")
    func directTouchPreservesClientDesktopCursorPresentation() throws {
        let view = try makeDesktopContentView(
            cursorPresentation: MirageDesktopCursorPresentation(source: .client),
            directTouchInputMode: .normal
        )

        #expect(!view.syntheticCursorEnabled)
        #expect(!view.desktopLocalCursorHidden)
    }

    @MainActor
    private func makeDesktopContentView(
        cursorPresentation: MirageDesktopCursorPresentation,
        directTouchInputMode: MirageDirectTouchInputMode
    ) throws -> MirageStreamContentView {
        let store = MirageClientSessionStore()
        let service = MirageClientService()
        let streamID: StreamID = 701
        let sessionID = store.createSession(
            streamID: streamID,
            mediaStreamID: streamID,
            window: MirageWindow(
                id: 70101,
                title: "Desktop",
                application: nil,
                frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                isOnScreen: true,
                windowLayer: 0
            ),
            hostName: "Host",
            streamKind: .desktop,
            minSize: nil
        )
        let session = try #require(store.session(for: sessionID))

        return MirageStreamContentView(
            session: session,
            sessionStore: store,
            clientService: service,
            isDesktopStream: true,
            desktopCursorPresentation: cursorPresentation,
            directTouchInputMode: directTouchInputMode
        )
    }
    #endif
}
