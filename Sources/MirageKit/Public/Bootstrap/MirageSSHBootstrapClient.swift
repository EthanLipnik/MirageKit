//
//  MirageSSHBootstrapClient.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  SSH abstraction for FileVault bootstrap unlock.
//

import Foundation
#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
#if canImport(CryptoKit)
import CryptoKit
#endif
#endif

/// Result of a bootstrap SSH unlock attempt.
public struct MirageSSHBootstrapResult: Sendable, Equatable {
    /// Whether target reported successful volume unlock.
    public let unlocked: Bool

    public init(unlocked: Bool) {
        self.unlocked = unlocked
    }
}

/// SSH bootstrap errors.
public enum MirageSSHBootstrapError: LocalizedError, Sendable, Equatable {
    case unsupported
    case connectionFailed(String)
    case authenticationFailed
    case timedOut
    case invalidEndpoint

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "SSH bootstrap is not available on this platform build."
        case let .connectionFailed(detail):
            "SSH bootstrap connection failed: \(detail)"
        case .authenticationFailed:
            "SSH bootstrap authentication failed."
        case .timedOut:
            "SSH bootstrap timed out."
        case .invalidEndpoint:
            "SSH bootstrap endpoint is invalid."
        }
    }
}

/// Cross-platform SSH client contract for pre-login bootstrap.
public protocol MirageSSHBootstrapClient: Sendable {
    func unlockVolumeOverSSH(
        endpoint: MirageBootstrapEndpoint,
        username: String,
        password: String,
        expectedHostKeyFingerprint: String?,
        timeout: Duration
    ) async throws -> MirageSSHBootstrapResult
}

/// Default implementation placeholder.
///
/// Platforms can inject a concrete implementation where available.
public struct MirageDefaultSSHBootstrapClient: MirageSSHBootstrapClient {
    public init() {}

    public func unlockVolumeOverSSH(
        endpoint: MirageBootstrapEndpoint,
        username: String,
        password: String,
        expectedHostKeyFingerprint: String? = nil,
        timeout: Duration
    )
    async throws -> MirageSSHBootstrapResult {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw MirageSSHBootstrapError.invalidEndpoint }
        guard endpoint.port > 0 else { throw MirageSSHBootstrapError.invalidEndpoint }

#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
        let timeoutNanoseconds = Self.timeoutNanoseconds(timeout)
        guard timeoutNanoseconds > 0 else { throw MirageSSHBootstrapError.timedOut }

        return try await withThrowingTaskGroup(of: MirageSSHBootstrapResult.self) { group in
            group.addTask {
                try await Self.performUnlock(
                    host: host,
                    port: Int(endpoint.port),
                    username: username,
                    password: password,
                    expectedHostKeyFingerprint: expectedHostKeyFingerprint
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MirageSSHBootstrapError.timedOut
            }

            guard let first = try await group.next() else {
                throw MirageSSHBootstrapError.connectionFailed("Missing SSH bootstrap result.")
            }
            group.cancelAll()
            return first
        }
#else
        throw MirageSSHBootstrapError.unsupported
#endif
    }
}

#if canImport(NIOConcurrencyHelpers) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
private extension MirageDefaultSSHBootstrapClient {
    static func performUnlock(
        host: String,
        port: Int,
        username: String,
        password: String,
        expectedHostKeyFingerprint: String?
    ) async throws -> MirageSSHBootstrapResult {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let authDelegate = SinglePasswordAuthenticationDelegate(
            username: username,
            password: password
        )
        let serverAuthDelegate = HostKeyValidationDelegate(
            expectedFingerprint: expectedHostKeyFingerprint
        )

        do {
            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: serverAuthDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(sshHandler)
                    }
                }
                .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(SOL_SOCKET),
                    SO_REUSEADDR
                ), value: 1)
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(IPPROTO_TCP),
                    TCP_NODELAY
                ), value: 1)

            let channel = try await bootstrap.connect(host: host, port: port).get()
            defer {
                _ = channel.close(mode: .all)
            }

            let exitStatusPromise = channel.eventLoop.makePromise(of: Int32.self)
            let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let childPromise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            MirageSSHBootstrapError.connectionFailed("Unexpected SSH channel type.")
                        )
                    }

                    let handler = SSHExecRequestHandler(
                        command: "/usr/bin/true",
                        exitStatusPromise: exitStatusPromise
                    )
                    return childChannel.pipeline.addHandler(handler)
                }
                return childPromise.futureResult
            }.get()

            let exitStatus = try await exitStatusPromise.futureResult.get()
            _ = try? await childChannel.closeFuture.get()

            try await shutdownEventLoopGroup(eventLoopGroup)
            guard exitStatus == 0 else {
                throw MirageSSHBootstrapError.connectionFailed(
                    "SSH unlock probe command returned status \(exitStatus)."
                )
            }
            return MirageSSHBootstrapResult(unlocked: true)
        } catch let error as MirageSSHBootstrapError {
            try? await shutdownEventLoopGroup(eventLoopGroup)
            throw error
        } catch {
            try? await shutdownEventLoopGroup(eventLoopGroup)
            throw mapToBootstrapError(error)
        }
    }

    static func timeoutNanoseconds(_ timeout: Duration) -> UInt64 {
        let components = timeout.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondNanos = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let fractionalNanos = UInt64(attoseconds / 1_000_000_000)
        if secondNanos.overflow {
            return UInt64.max
        }
        let total = secondNanos.partialValue.addingReportingOverflow(fractionalNanos)
        return total.overflow ? UInt64.max : total.partialValue
    }

    static func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func mapToBootstrapError(_ error: Error) -> MirageSSHBootstrapError {
        if let error = error as? MirageSSHBootstrapError { return error }

        let description = error.localizedDescription.lowercased()
        if description.contains("auth") || description.contains("permission denied") {
            return .authenticationFailed
        }
        if description.contains("timed out") || description.contains("timeout") {
            return .timedOut
        }

        return .connectionFailed(error.localizedDescription)
    }
}

private final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = Self.normalizedFingerprint(expectedFingerprint)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            guard let expectedFingerprint else {
                validationCompletePromise.succeed(())
                return
            }

            let receivedFingerprint = try Self.fingerprint(for: hostKey)
            guard receivedFingerprint == expectedFingerprint else {
                throw MirageSSHBootstrapError.connectionFailed(
                    "SSH host key fingerprint mismatch (expected \(expectedFingerprint), got \(receivedFingerprint))."
                )
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased().hasPrefix("SHA256:") {
            let suffix = String(trimmed.dropFirst("SHA256:".count))
            return "SHA256:\(suffix)"
        }
        return "SHA256:\(trimmed)"
    }

    private static func fingerprint(for hostKey: NIOSSHPublicKey) throws -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let components = openSSH.split(separator: " ")
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            throw MirageSSHBootstrapError.connectionFailed("Failed to derive host key fingerprint.")
        }

#if canImport(CryptoKit)
        let digest = SHA256.hash(data: keyData)
        let fingerprint = Data(digest).base64EncodedString()
        return "SHA256:\(fingerprint)"
#else
        throw MirageSSHBootstrapError.connectionFailed("Host key fingerprinting is unavailable on this platform build.")
#endif
    }
}

private final class SinglePasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var password: String?
    private let lock = NIOLock()
    private var offeredPassword = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(MirageSSHBootstrapError.authenticationFailed)
            return
        }

        lock.withLock {
            if offeredPassword {
                password = nil
                nextChallengePromise.fail(MirageSSHBootstrapError.authenticationFailed)
            } else {
                guard let password else {
                    nextChallengePromise.fail(MirageSSHBootstrapError.authenticationFailed)
                    return
                }
                offeredPassword = true
                self.password = nil
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: .password(.init(password: password))
                    )
                )
            }
        }
    }
}

private final class SSHExecRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let exitStatusPromise: EventLoopPromise<Int32>
    private let lock = NIOLock()
    private var completed = false

    init(command: String, exitStatusPromise: EventLoopPromise<Int32>) {
        self.command = command
        self.exitStatusPromise = exitStatusPromise
    }

    func channelActive(context: ChannelHandlerContext) {
        let event = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(event).assumeIsolated().whenFailure { [weak self] error in
            self?.complete(with: error)
            context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        _ = unwrapInboundIn(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            complete(with: Int32(status.exitStatus))
            context.close(promise: nil)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            complete(
                with: MirageSSHBootstrapError.connectionFailed(
                    "SSH remote exited with signal \(signal.signalName)."
                )
            )
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(with: error)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete(
            with: MirageSSHBootstrapError.connectionFailed(
                "SSH channel closed before command exit status was received."
            )
        )
        context.fireChannelInactive()
    }

    private func complete(with status: Int32) {
        lock.withLock {
            guard !completed else { return }
            completed = true
            exitStatusPromise.succeed(status)
        }
    }

    private func complete(with error: Error) {
        lock.withLock {
            guard !completed else { return }
            completed = true
            exitStatusPromise.fail(error)
        }
    }
}
#endif
