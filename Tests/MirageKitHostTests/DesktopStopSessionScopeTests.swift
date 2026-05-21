//
//  DesktopStopSessionScopeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Desktop Stop Session Scope")
struct DesktopStopSessionScopeTests {
    @Test("Desktop stop requests are ignored when the desktop session has been replaced")
    func desktopStopRequestsAreIgnoredWhenDesktopSessionHasBeenReplaced() {
        #expect(
            shouldAcceptStopDesktopStreamRequest(
                requestedStreamID: 21,
                requestedDesktopSessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                activeDesktopStreamID: 21,
                activeDesktopSessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ) == false
        )
    }

    @Test("Desktop stop requests are accepted for the active desktop session")
    func desktopStopRequestsAreAcceptedForTheActiveDesktopSession() {
        let desktopSessionID = UUID()

        #expect(
            shouldAcceptStopDesktopStreamRequest(
                requestedStreamID: 21,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: 21,
                activeDesktopSessionID: desktopSessionID
            )
        )
    }

    @Test("Deferred display cleanup continues only for the current inactive generation")
    func deferredDisplayCleanupContinuesOnlyForTheCurrentInactiveGeneration() {
        #expect(MirageHostService.shouldContinueDeferredDesktopDisplayCleanup(
            cleanupGeneration: 4,
            currentGeneration: 4,
            isCancelled: false,
            hasActiveDesktopStream: false
        ))
    }

    @Test("Deferred display cleanup cancels when a new desktop stream starts")
    func deferredDisplayCleanupCancelsWhenANewDesktopStreamStarts() {
        #expect(!MirageHostService.shouldContinueDeferredDesktopDisplayCleanup(
            cleanupGeneration: 4,
            currentGeneration: 5,
            isCancelled: false,
            hasActiveDesktopStream: false
        ))
        #expect(!MirageHostService.shouldContinueDeferredDesktopDisplayCleanup(
            cleanupGeneration: 4,
            currentGeneration: 4,
            isCancelled: false,
            hasActiveDesktopStream: true
        ))
    }

    @Test("Deferred display cleanup stops immediately when its task is cancelled")
    func deferredDisplayCleanupStopsImmediatelyWhenItsTaskIsCancelled() {
        #expect(!MirageHostService.shouldContinueDeferredDesktopDisplayCleanup(
            cleanupGeneration: 4,
            currentGeneration: 4,
            isCancelled: true,
            hasActiveDesktopStream: false
        ))
    }
}
#endif
