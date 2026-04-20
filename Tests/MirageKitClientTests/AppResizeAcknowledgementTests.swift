//
//  AppResizeAcknowledgementTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/27/26.
//

@testable import MirageKitClient
import Testing

@Suite("App Resize Acknowledgement")
struct AppResizeAcknowledgementTests {
    @MainActor
    @Test("App resize ack ignores stale stream-start echoes")
    func ignoresStaleStreamStartEchoes() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let stale = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )

        #expect(!isMeaningfulAppResizeAcknowledgement(stale, comparedTo: baseline))
    }

    @MainActor
    @Test("App resize ack accepts dimension-token advances")
    func acceptsDimensionTokenAdvance() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let advanced = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 8
        )

        #expect(isMeaningfulAppResizeAcknowledgement(advanced, comparedTo: baseline))
    }

    @MainActor
    @Test("App resize stream-start handling ignores encoded dimensions when no resize ack is pending")
    func ignoresEncodedDimensionsWhenResizeAckIsNotPending() {
        let acknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 2720,
            height: 2016,
            dimensionToken: 8
        )

        let decision = appStreamStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: false,
            latest: acknowledgement,
            baseline: nil
        )

        #expect(decision == .ignore)
    }

    @MainActor
    @Test("App resize stream-start handling rechecks minimum size only after meaningful ack advance")
    func rechecksMinimumSizeAfterMeaningfulAckAdvance() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let acknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 8
        )

        let decision = appStreamStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: true,
            latest: acknowledgement,
            baseline: baseline
        )

        #expect(decision == .recheckMinimumSize)
    }

    @MainActor
    @Test("App resize stream-start handling rechecks minimum size after encoded dimensions change")
    func rechecksMinimumSizeAfterEncodedDimensionsChange() {
        let baseline = MirageClientService.StreamStartAcknowledgement(
            width: 2416,
            height: 1664,
            dimensionToken: 7
        )
        let acknowledgement = MirageClientService.StreamStartAcknowledgement(
            width: 2720,
            height: 1530,
            dimensionToken: 8
        )

        let decision = appStreamStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: true,
            latest: acknowledgement,
            baseline: baseline
        )

        #expect(decision == .recheckMinimumSize)
    }
}
