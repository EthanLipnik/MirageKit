//
//  MirageClientAudioSessionCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Coverage for shared playback/dictation audio-session arbitration.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Client Audio Session Coordinator")
struct MirageClientAudioSessionCoordinatorTests {
    @MainActor
    @Test("Playback and dictation share a single session owner")
    func playbackAndDictationShareASessionOwner() async {
        let driver = RecordingAudioSessionDriver()
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(await coordinator.requestPlaybackSession())
        #expect(driver.events == [.activate(.playback)])

        #expect(await coordinator.requestDictationSession())
        #expect(driver.events == [.activate(.playback), .activate(.dictation)])

        await coordinator.releasePlaybackSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation)])

        await coordinator.releaseDictationSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation), .deactivate])
    }

    @MainActor
    @Test("Dictation releases back to playback when playback lease remains")
    func dictationRestoresPlaybackWhenPlaybackLeaseRemains() async {
        let driver = RecordingAudioSessionDriver()
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(await coordinator.requestPlaybackSession())
        #expect(await coordinator.requestDictationSession())

        await coordinator.releaseDictationSession()

        #expect(driver.events == [.activate(.playback), .activate(.dictation), .activate(.playback)])

        await coordinator.releasePlaybackSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation), .activate(.playback), .deactivate])
    }

    @MainActor
    @Test("Inactive app defers session activation")
    func inactiveAppDefersSessionActivation() async {
        let driver = RecordingAudioSessionDriver(isApplicationActive: false)
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(await coordinator.requestPlaybackSession() == false)
        #expect(driver.events.isEmpty)

        await coordinator.releasePlaybackSession()
        driver.setApplicationActive(true)

        #expect(await coordinator.requestPlaybackSession())
        #expect(driver.events == [.activate(.playback)])
    }

    @MainActor
    @Test("Dictation request waits briefly for app activation")
    func dictationRequestWaitsBrieflyForAppActivation() async {
        let driver = RecordingAudioSessionDriver(
            isApplicationActive: false,
            activateAfterInactiveChecks: 2
        )
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(await coordinator.requestDictationSession())
        #expect(driver.events == [.activate(.dictation)])

        await coordinator.releaseDictationSession()
        #expect(driver.events == [.activate(.dictation), .deactivate])
    }
}

private final class RecordingAudioSessionDriver: MirageClientAudioSessionDriving, @unchecked Sendable {
    enum Event: Equatable {
        case activate(MirageClientAudioSessionConfiguration)
        case deactivate
    }

    private let lock = NSLock()
    private var isApplicationActiveValue: Bool
    private var remainingInactiveChecksBeforeActivation: Int?
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock {
            recordedEvents
        }
    }

    init(
        isApplicationActive: Bool = true,
        activateAfterInactiveChecks: Int? = nil
    ) {
        self.isApplicationActiveValue = isApplicationActive
        self.remainingInactiveChecksBeforeActivation = activateAfterInactiveChecks
    }

    func setApplicationActive(_ isActive: Bool) {
        lock.withLock {
            isApplicationActiveValue = isActive
        }
    }

    var isApplicationActive: Bool {
        get async {
            lock.withLock {
                if !isApplicationActiveValue,
                   let remainingInactiveChecksBeforeActivation {
                    if remainingInactiveChecksBeforeActivation <= 0 {
                        isApplicationActiveValue = true
                        self.remainingInactiveChecksBeforeActivation = nil
                    } else {
                        self.remainingInactiveChecksBeforeActivation = remainingInactiveChecksBeforeActivation - 1
                    }
                }
                return isApplicationActiveValue
            }
        }
    }

    func activatePlaybackSession() async throws {
        lock.withLock {
            recordedEvents.append(.activate(.playback))
        }
    }

    func activateDictationSession() async throws {
        lock.withLock {
            recordedEvents.append(.activate(.dictation))
        }
    }

    func deactivate() async throws {
        lock.withLock {
            recordedEvents.append(.deactivate)
        }
    }
}
#endif
