//
//  ClientControlSessionFailureClassificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Loom
import Network
import Testing

@Suite("Client Control Session Failure Classification")
struct ClientControlSessionFailureClassificationTests {
    @MainActor
    @Test("Client control session failures classify retryable transport errors")
    func controlSessionFailureClassificationRecognizesRetryableTransportErrors() {
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ENETUNREACH))
            ) == .transportLoss
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.ECONNREFUSED))
            ) == .connectionRefused
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(NWError.posix(.EADDRNOTAVAIL))
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(
                    NWError.dns(-65554)
                )
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.connectionFailed(
                    LoomConnectionFailure(
                        reason: .timedOut,
                        detail: "Reliable UDP transport timed out awaiting acknowledgement."
                    )
                )
            ) == .timeout
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(MirageError.timeout) == .timeout
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                LoomError.protocolError("Failed to resolve zephir-m3.local: nodename nor servname provided, or not known")
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError("Failed to resolve zephir-m3.local: nodename nor servname provided, or not known")
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError(
                    "Pre-bootstrap udp control session failed for zephir-m3 endpoint=zephir-m3.local:51024 " +
                        "interface=wifi classification=other error=Protocol error: Failed to resolve " +
                        "zephir-m3.local: nodename nor servname provided, or not known"
                )
            ) == .addressUnavailable
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError("Timed out waiting for host bootstrap response from Altair")
            ) == .timeout
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError("Control stream closed before receiving bootstrap response")
            ) == .transportLoss
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError(
                    "Proximity path validation failed for Altair expected=anpi0 actual=status=satisfied|kind=wifi|if=en0"
                )
            ) == .transportLoss
        )
        #expect(
            MirageClientService.classifyControlSessionFailure(
                MirageError.protocolError("Host identity mismatch")
            ) == .hostIdentityMismatch
        )
    }

    @MainActor
    @Test("Client retries later direct transports for retryable failures")
    func retryPolicyContinuesThroughLaterAdvertisedTransports() throws {
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61010))
        let quicPort = try #require(NWEndpoint.Port(rawValue: 61011))
        let tcpPort = try #require(NWEndpoint.Port(rawValue: 61012))
        let attempts = [
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: udpPort),
                transportKind: .udp,
                candidateKind: .local,
                requiredInterfaceType: nil
            ),
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: quicPort),
                transportKind: .quic,
                candidateKind: .local,
                requiredInterfaceType: nil
            ),
            MirageClientService.ControlSessionAttempt(
                hostName: "Altair",
                endpoint: .hostPort(host: NWEndpoint.Host("altair.local"), port: tcpPort),
                transportKind: .tcp,
                candidateKind: .local,
                requiredInterfaceType: nil
            ),
        ]

        #expect(
            MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .addressUnavailable,
                attempts: attempts,
                currentAttemptIndex: 0
            )
        )
        #expect(
            MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .timeout,
                attempts: attempts,
                currentAttemptIndex: 1
            )
        )
        #expect(
            !MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .addressUnavailable,
                attempts: attempts,
                currentAttemptIndex: 2
            )
        )
        #expect(
            !MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .other,
                attempts: attempts,
                currentAttemptIndex: 0
            )
        )
        #expect(
            !MirageClientService.shouldRetryLaterControlSessionAttempt(
                classification: .hostIdentityMismatch,
                attempts: attempts,
                currentAttemptIndex: 0
            )
        )
    }

    @MainActor
    @Test("Client retries unexpected bootstrap cancellations as transport loss")
    func bootstrappedControlSessionFailureClassificationRetriesUnexpectedCancellation() {
        #expect(
            MirageClientService.classifyBootstrappedControlSessionFailure(
                CancellationError(),
                isCurrentAttempt: true,
                taskIsCancelled: false
            ) == .transportLoss
        )
        #expect(
            MirageClientService.classifyBootstrappedControlSessionFailure(
                CancellationError(),
                isCurrentAttempt: false,
                taskIsCancelled: false
            ) == nil
        )
        #expect(
            MirageClientService.classifyBootstrappedControlSessionFailure(
                CancellationError(),
                isCurrentAttempt: true,
                taskIsCancelled: true
            ) == nil
        )
    }

    @MainActor
    @Test("Client retries the current transport once after bootstrap transport loss")
    func bootstrappedControlSessionRetryPolicyRetriesCurrentTransportOnce() {
        #expect(
            MirageClientService.shouldRetryCurrentBootstrappedControlSessionAttempt(
                classification: .transportLoss,
                controlChannelOpened: true,
                hasRetriedCurrentAttempt: false
            )
        )
        #expect(
            !MirageClientService.shouldRetryCurrentBootstrappedControlSessionAttempt(
                classification: .transportLoss,
                controlChannelOpened: true,
                hasRetriedCurrentAttempt: true
            )
        )
        #expect(
            !MirageClientService.shouldRetryCurrentBootstrappedControlSessionAttempt(
                classification: .transportLoss,
                controlChannelOpened: false,
                hasRetriedCurrentAttempt: false
            )
        )
        #expect(
            !MirageClientService.shouldRetryCurrentBootstrappedControlSessionAttempt(
                classification: .timeout,
                controlChannelOpened: true,
                hasRetriedCurrentAttempt: false
            )
        )
    }
}
