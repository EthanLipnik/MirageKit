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
        driver.isApplicationActiveValue = true

        #expect(await coordinator.requestPlaybackSession())
        #expect(driver.events == [.activate(.playback)])
    }
}

private final class RecordingAudioSessionDriver: MirageClientAudioSessionDriving, @unchecked Sendable {
    enum Event: Equatable {
        case activate(MirageClientAudioSessionConfiguration)
        case deactivate
    }

    var isApplicationActiveValue: Bool
    private(set) var events: [Event] = []

    init(isApplicationActive: Bool = true) {
        self.isApplicationActiveValue = isApplicationActive
    }

    func isApplicationActive() async -> Bool {
        isApplicationActiveValue
    }

    func activate(_ configuration: MirageClientAudioSessionConfiguration) async throws {
        events.append(.activate(configuration))
    }

    func deactivate() async throws {
        events.append(.deactivate)
    }
}
#endif
