//
//  DesktopResizeStartAcknowledgementHandlingDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Desktop Resize Start Acknowledgement Handling Decision")
struct DesktopResizeStartAcknowledgementHandlingDecisionTests {
    @Test("Duplicate same-token start keeps waiting for resize advance")
    func duplicateSameTokenStartKeepsWaiting() {
        let decision = desktopResizeStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: true,
            acknowledgementProgressStarted: false,
            latest: acknowledgement(width: 2732, height: 2048, token: 12),
            baseline: acknowledgement(width: 2732, height: 2048, token: 12)
        )

        #expect(decision == .waitForResizeAdvance)
    }

    @Test("Token advance begins convergence checks")
    func tokenAdvanceBeginsConvergenceChecks() {
        let decision = desktopResizeStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: true,
            acknowledgementProgressStarted: false,
            latest: acknowledgement(width: 3200, height: 2400, token: 13),
            baseline: acknowledgement(width: 2732, height: 2048, token: 12)
        )

        #expect(decision == .beginConvergenceCheck)
    }

    @Test("Once token advance is observed later checks keep converging")
    func laterChecksKeepConvergingAfterTokenAdvance() {
        let decision = desktopResizeStartAcknowledgementHandlingDecision(
            awaitingResizeAcknowledgement: true,
            acknowledgementProgressStarted: true,
            latest: acknowledgement(width: 3200, height: 2400, token: 13),
            baseline: acknowledgement(width: 2732, height: 2048, token: 12)
        )

        #expect(decision == .continueConvergenceCheck)
    }

    private func acknowledgement(
        width: Int,
        height: Int,
        token: UInt16?
    ) -> MirageClientService.StreamStartAcknowledgement {
        MirageClientService.StreamStartAcknowledgement(
            width: width,
            height: height,
            dimensionToken: token
        )
    }
}
#endif
