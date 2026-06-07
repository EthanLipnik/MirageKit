//
//  MirageConnectivityConnectionErrorClassifierTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageCore
@testable import MirageConnectivity
import Network
import Testing

@Suite("Mirage Connectivity Connection Error Classifier")
struct MirageConnectivityConnectionErrorClassifierTests {
    @Test("Closed Loom bootstrap sessions are expected bootstrap closures")
    func closedLoomBootstrapSessionIsExpected() {
        let error = LoomConnectionFailure(
            reason: .closed,
            detail: "Authenticated Loom session closed before Mirage control stream opened"
        )

        #expect(MirageConnectionErrorClassifier.isExpectedBootstrapConnectionClosure(error))
    }

    @Test("Control stream closure error is expected bootstrap closure")
    func controlStreamClosureErrorIsExpectedBootstrapClosure() {
        let error = MirageConnectionErrors.authenticatedSessionClosedBeforeControlStreamOpened()

        #expect(MirageConnectionErrorClassifier.isExpectedBootstrapConnectionClosure(error))
        #expect(MirageConnectionErrorClassifier.isFatalConnectionError(error))
    }

    @Test("Loom connection failures unwrap for expected lifecycle send failures")
    func loomConnectionFailureWrapperIsExpectedLifecycleFailure() {
        let error = LoomError.connectionFailed(
            LoomConnectionFailure(
                reason: .cancelled,
                detail: "Cancelled during disconnect"
            )
        )

        #expect(MirageConnectionErrorClassifier.isExpectedLifecycleControlSendFailure(error))
    }

    @Test("Mirage connection-failed wrapper is fatal for closed Loom sessions")
    func closedBootstrapSessionWrappedAsMirageConnectionFailureIsFatal() {
        let error = MirageCore.MirageError.connectionFailed(
            LoomConnectionFailure(
                reason: .closed,
                detail: "Authenticated Loom session closed before Mirage control stream opened"
            )
        )

        #expect(MirageConnectionErrorClassifier.isFatalConnectionError(error))
    }

    @Test("Audio send pressure recognizes cancelled Loom queues")
    func audioSendPressureRecognizesCancelledLoomQueues() {
        let posixCancelled = LoomConnectionFailure(
            reason: .cancelled,
            posixCode: .ECANCELED,
            detail: "Cancelled send"
        )
        let queueCancelled = LoomConnectionFailure(
            reason: .cancelled,
            detail: "Unreliable send queue cancelled."
        )
        let wrapped = MirageCore.MirageError.connectionFailed(queueCancelled)

        #expect(MirageConnectionErrorClassifier.isRecoverableAudioSendPressure(posixCancelled))
        #expect(MirageConnectionErrorClassifier.isRecoverableAudioSendPressure(queueCancelled))
        #expect(MirageConnectionErrorClassifier.isRecoverableAudioSendPressure(wrapped))
    }

    @Test("Client control session failures classify retryable transport errors")
    func controlSessionFailureClassificationRecognizesRetryableTransportErrors() {
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ENETUNREACH))
            ) == .transportLoss
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ECONNREFUSED))
            ) == .connectionRefused
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                MirageCore.MirageError.connectionFailed(NWError.posix(.EADDRNOTAVAIL))
            ) == .addressUnavailable
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                MirageCore.MirageError.connectionFailed(NWError.dns(-65554))
            ) == .addressUnavailable
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                LoomConnectionFailure(
                    reason: .timedOut,
                    detail: "Reliable UDP transport timed out awaiting acknowledgement."
                )
            ) == .timeout
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                LoomError.protocolError("Failed to resolve zephir-m3.local: nodename nor servname provided, or not known")
            ) == .addressUnavailable
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                MirageCore.MirageError.protocolError("Timed out waiting for host bootstrap response from Altair")
            ) == .timeout
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                MirageCore.MirageError.protocolError("Control stream closed before receiving bootstrap response")
            ) == .transportLoss
        )
        #expect(
            MirageConnectionErrorClassifier.classifyControlSessionFailure(
                MirageCore.MirageError.protocolError(
                    "Proximity path validation failed for Altair expected=anpi0 actual=status=satisfied|kind=wifi|if=en0"
                )
            ) == .transportLoss
        )
    }

    @Test("Best-effort input send failures recognize expected teardown errors")
    func bestEffortInputSendFailuresRecognizeExpectedTeardownErrors() {
        #expect(MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(CancellationError()))
        #expect(
            MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                LoomError.connectionFailed(
                    LoomConnectionFailure(reason: .closed, detail: "Peer closed control stream")
                )
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                NSError(domain: "Loom.LoomError", code: 0)
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                NSError(domain: "Loom.LoomError", code: 3)
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                MirageCore.MirageError.connectionFailed(NWError.posix(.ECONNRESET))
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EPIPE.rawValue))
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                NSError(domain: "Loom.LoomError", code: 2)
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(
                NWError.posix(.ETIMEDOUT)
            )
        )
    }

    @Test("Realtime input queue drops recognize cancelled sends")
    func realtimeInputQueueDropsRecognizeCancelledSends() {
        #expect(
            MirageConnectionErrorClassifier.isExpectedRealtimeInputQueueDrop(
                NWError.posix(.ECANCELED)
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isExpectedRealtimeInputQueueDrop(
                NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECANCELED.rawValue))
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isExpectedRealtimeInputQueueDrop(
                NWError.posix(.ECONNRESET)
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isExpectedRealtimeInputQueueDrop(
                LoomError.connectionFailed(NWError.posix(.ECANCELED))
            )
        )
    }

    @Test("Host listener start failures classify retryable address conflicts")
    func hostListenerStartFailuresClassifyRetryableAddressConflicts() {
        #expect(
            MirageConnectionErrorClassifier.isRetryableListenerStartError(
                NWError.posix(.EADDRINUSE)
            )
        )
        #expect(
            MirageConnectionErrorClassifier.isRetryableListenerStartError(
                NWError.posix(.EADDRNOTAVAIL)
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isRetryableListenerStartError(
                NWError.posix(.ECONNRESET)
            )
        )
        #expect(
            !MirageConnectionErrorClassifier.isRetryableListenerStartError(
                NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EADDRINUSE.rawValue))
            )
        )
    }
}
