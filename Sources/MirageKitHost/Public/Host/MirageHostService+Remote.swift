//
//  MirageHostService+Remote.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Remote QUIC control listener lifecycle and STUN candidate publication helpers.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
private final class RemoteListenerCompletionFlag: @unchecked Sendable {
    private var completed = false
    private let lock = NSLock()

    func completeOnce() -> Bool {
        lock.withLock {
            if completed { return false }
            completed = true
            return true
        }
    }
}

@MainActor
extension MirageHostService {
    /// Starts or stops the remote QUIC listener based on host state and preferences.
    func updateRemoteControlListenerState() async {
        let isHosting: Bool
        if case .advertising = state {
            isHosting = true
        } else {
            isHosting = false
        }

        guard remoteTransportEnabled, isHosting else {
            stopRemoteControlListener()
            return
        }

        do {
            let port = try await startRemoteControlListenerIfNeeded()
            MirageLogger.host("Remote QUIC listener active on port \(port)")
        } catch {
            MirageLogger.error(.host, "Failed to start remote QUIC listener: \(error)")
        }
    }

    /// Resolves a STUN-reflexive candidate for the active remote QUIC listener.
    public func resolveRemoteControlCandidate(
        stunHost: String = "stun.cloudflare.com",
        stunPort: UInt16 = 3478,
        timeout: Duration = .seconds(2)
    )
    async -> MirageRemoteCandidate? {
        guard remoteTransportEnabled,
              let localPort = remoteControlPort else {
            return nil
        }

        let result = await MirageStunProbe.run(
            host: stunHost,
            port: stunPort,
            localPort: localPort,
            timeout: timeout
        )
        guard result.reachable,
              let mappedAddress = result.mappedAddress,
              let mappedPort = result.mappedPort else {
            if let failureReason = result.failureReason {
                MirageLogger.host("Remote STUN probe failed: \(failureReason)")
            }
            return nil
        }

        return MirageRemoteCandidate(
            transport: .quic,
            address: mappedAddress,
            port: mappedPort
        )
    }

    private func startRemoteControlListenerIfNeeded() async throws -> UInt16 {
        if let remoteControlPort {
            return remoteControlPort
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: ["mirage-v2"])
        let parameters = NWParameters(quic: quicOptions)
        parameters.serviceClass = .interactiveVideo
        parameters.allowLocalEndpointReuse = true

        let requestedPort: NWEndpoint.Port = {
            if let existingPort = remoteControlPort,
               let port = NWEndpoint.Port(rawValue: existingPort) {
                return port
            }
            if networkConfig.controlPort == 0 {
                return .any
            }
            return NWEndpoint.Port(rawValue: networkConfig.controlPort) ?? .any
        }()

        let listener = try NWListener(using: parameters, on: requestedPort)
        remoteControlListener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                await self?.handleNewConnection(connection)
            }
        }

        let completionFlag = RemoteListenerCompletionFlag()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self, completionFlag] state in
                switch state {
                case .ready:
                    guard completionFlag.completeOnce() else { return }
                    guard let boundPort = listener.port?.rawValue else {
                        continuation.resume(throwing: MirageError.protocolError("Remote QUIC listener missing port"))
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.setRemoteControlPort(boundPort)
                    }
                    continuation.resume(returning: boundPort)

                case let .failed(error):
                    guard completionFlag.completeOnce() else { return }
                    Task { @MainActor [weak self] in
                        self?.remoteControlListener = nil
                        self?.setRemoteControlPort(nil)
                    }
                    continuation.resume(throwing: error)

                case .cancelled:
                    guard completionFlag.completeOnce() else { return }
                    Task { @MainActor [weak self] in
                        self?.remoteControlListener = nil
                        self?.setRemoteControlPort(nil)
                    }
                    continuation.resume(throwing: MirageError.protocolError("Remote QUIC listener cancelled"))

                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func stopRemoteControlListener() {
        remoteControlListener?.cancel()
        remoteControlListener = nil
        setRemoteControlPort(nil)
    }
}
#endif
