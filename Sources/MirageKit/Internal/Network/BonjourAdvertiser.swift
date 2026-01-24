//
//  BonjourAdvertiser.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network

/// Advertises the Mirage host service via Bonjour
actor BonjourAdvertiser {
    private var listener: NWListener?
    private let serviceType: String
    private let serviceName: String
    private let capabilities: MirageHostCapabilities
    private let enablePeerToPeer: Bool

    private var isAdvertising = false

    init(
        serviceName: String,
        capabilities: MirageHostCapabilities = MirageHostCapabilities(),
        serviceType: String = MirageKit.serviceType,
        enablePeerToPeer: Bool = true
    ) {
        self.serviceName = serviceName
        self.capabilities = capabilities
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
    }

    /// Start advertising the service
    func start(port: UInt16 = 0, onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        guard !isAdvertising else {
            throw MirageError.alreadyAdvertising
        }

        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = enablePeerToPeer

        // Enable TCP_NODELAY for low latency
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }

        let actualPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!

        listener = try NWListener(using: parameters, on: actualPort)

        // Configure Bonjour advertisement with TXT record
        let txtRecord = NWTXTRecord(capabilities.toTXTRecord())
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            txtRecord: txtRecord
        )

        // Set connection handler BEFORE starting the listener
        listener?.newConnectionHandler = onConnection

        // Capture listener reference for the closure
        guard let listener = self.listener else {
            throw MirageError.protocolError("Failed to create listener")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)

            listener.stateUpdateHandler = { [weak self, continuationBox] state in
                MirageLogger.network("Advertiser state: \(state)")
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        Task { await self?.setAdvertising(true) }
                        continuationBox.resume(returning: port)
                    }
                case .failed(let error):
                    Task { await self?.setAdvertising(false) }
                    continuationBox.resume(throwing: error)
                case .waiting(let error):
                    MirageLogger.network("Advertiser waiting: \(error)")
                case .cancelled:
                    Task { await self?.setAdvertising(false) }
                    continuationBox.resume(throwing: MirageError.protocolError("Listener cancelled"))
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInteractive))
        }
    }

    private func setAdvertising(_ value: Bool) {
        isAdvertising = value
    }

    /// Stop advertising
    func stop() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
    }

    /// Update TXT record with new capabilities
    func updateCapabilities(_ capabilities: MirageHostCapabilities) {
        let txtRecord = NWTXTRecord(capabilities.toTXTRecord())
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            txtRecord: txtRecord
        )
    }

    var port: UInt16? {
        listener?.port?.rawValue
    }
}

/// Mirage-specific errors
public enum MirageError: Error, LocalizedError {
    case alreadyAdvertising
    case notAdvertising
    case connectionFailed(Error)
    case authenticationFailed
    case streamNotFound
    case windowNotFound
    case encodingError(Error)
    case decodingError(Error)
    case permissionDenied
    case timeout
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyAdvertising:
            return "Already advertising service"
        case .notAdvertising:
            return "Not currently advertising"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .authenticationFailed:
            return "Authentication failed"
        case .streamNotFound:
            return "Stream not found"
        case .windowNotFound:
            return "Window not found"
        case .encodingError(let error):
            return "Encoding error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .permissionDenied:
            return "Permission denied"
        case .timeout:
            return "Operation timed out"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        }
    }
}
