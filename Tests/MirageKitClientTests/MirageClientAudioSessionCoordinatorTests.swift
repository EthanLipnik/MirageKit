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
    func playbackAndDictationShareASessionOwner() {
        let driver = RecordingAudioSessionDriver()
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(coordinator.requestPlaybackSession())
        #expect(driver.events == [.activate(.playback)])

        #expect(coordinator.requestDictationSession())
        #expect(driver.events == [.activate(.playback), .activate(.dictation)])

        coordinator.releasePlaybackSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation)])

        coordinator.releaseDictationSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation), .deactivate])
    }

    @MainActor
    @Test("Dictation releases back to playback when playback lease remains")
    func dictationRestoresPlaybackWhenPlaybackLeaseRemains() {
        let driver = RecordingAudioSessionDriver()
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(coordinator.requestPlaybackSession())
        #expect(coordinator.requestDictationSession())

        coordinator.releaseDictationSession()

        #expect(driver.events == [.activate(.playback), .activate(.dictation), .activate(.playback)])

        coordinator.releasePlaybackSession()
        #expect(driver.events == [.activate(.playback), .activate(.dictation), .activate(.playback), .deactivate])
    }

    @MainActor
    @Test("Inactive app defers session activation")
    func inactiveAppDefersSessionActivation() {
        let driver = RecordingAudioSessionDriver(isApplicationActive: false)
        let coordinator = MirageClientAudioSessionCoordinator(driver: driver)

        #expect(coordinator.requestPlaybackSession() == false)
        #expect(driver.events.isEmpty)

        coordinator.releasePlaybackSession()
        driver.isApplicationActive = true

        #expect(coordinator.requestPlaybackSession())
        #expect(driver.events == [.activate(.playback)])
    }
}

private final class RecordingAudioSessionDriver: MirageClientAudioSessionDriving {
    enum Event: Equatable {
        case activate(MirageClientAudioSessionConfiguration)
        case deactivate
    }

    var isApplicationActive: Bool
    private(set) var events: [Event] = []

    init(isApplicationActive: Bool = true) {
        self.isApplicationActive = isApplicationActive
    }

    func activate(_ configuration: MirageClientAudioSessionConfiguration) throws {
        events.append(.activate(configuration))
    }

    func deactivate() throws {
        events.append(.deactivate)
    }
}
#endif
