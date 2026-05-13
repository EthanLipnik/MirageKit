//
//  MirageClientService+PingWaiters.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Shared ping waiter coordination for RTT sampling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    struct PingWaiterRegistration {
        let requestID: UInt64
        let startedNewRequest: Bool
    }

    func measureRTT(
        sendPing: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> Double {
        var samples: [Double] = []

        for _ in 0 ..< 3 {
            let start = CFAbsoluteTimeGetCurrent()
            try await sendPingAndAwaitPong(sendPing: sendPing)
            let delta = (CFAbsoluteTimeGetCurrent() - start) * 1000
            samples.append(delta)
        }

        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    func sendPingAndAwaitPong(
        timeout: Duration = .seconds(5),
        sendPing: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }
        let message = ControlMessage(type: .ping)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = registerPingWaiter(continuation, timeout: timeout)
            guard registration.startedNewRequest else { return }
            Task { @MainActor [weak self] in
                do {
                    if let sendPing {
                        try await sendPing()
                    } else {
                        try await self?.sendControlMessage(message)
                    }
                } catch {
                    self?.completePingRequest(
                        expectedRequestID: registration.requestID,
                        result: .failure(error)
                    )
                }
            }
        }
    }

    func registerPingWaiter(
        _ continuation: CheckedContinuation<Void, Error>,
        timeout: Duration = .seconds(5)
    ) -> PingWaiterRegistration {
        pingContinuations.append(continuation)
        if pingContinuations.count > 1 {
            return PingWaiterRegistration(
                requestID: pingRequestID,
                startedNewRequest: false
            )
        }

        pingRequestID &+= 1
        let requestID = pingRequestID
        pingTimeoutTask?.cancel()
        pingTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self.completePingRequest(
                expectedRequestID: requestID,
                result: .failure(MirageError.protocolError("Ping timed out"))
            )
        }

        return PingWaiterRegistration(
            requestID: requestID,
            startedNewRequest: true
        )
    }

    func failActivePingRequests(with error: Error) {
        guard !pingContinuations.isEmpty else {
            pingTimeoutTask?.cancel()
            pingTimeoutTask = nil
            return
        }
        completePingRequest(
            expectedRequestID: pingRequestID,
            result: .failure(error)
        )
    }

    func completePingRequest(
        expectedRequestID: UInt64,
        result: Result<Void, Error>
    ) {
        guard pingRequestID == expectedRequestID, !pingContinuations.isEmpty else { return }
        let continuations = pingContinuations
        pingContinuations.removeAll(keepingCapacity: false)
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        for continuation in continuations {
            switch result {
            case .success:
                continuation.resume()
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }
}
