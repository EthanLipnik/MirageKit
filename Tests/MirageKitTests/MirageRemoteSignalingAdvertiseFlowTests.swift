//
//  MirageRemoteSignalingAdvertiseFlowTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Remote Signaling Advertise Flow", .serialized)
struct MirageRemoteSignalingAdvertiseFlowTests {
    @MainActor
    @Test("Advertise uses heartbeat only when session already exists")
    func advertiseUsesHeartbeatWhenSessionExists() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertiseHostSession(
            sessionID: "session-1",
            hostID: Self.hostID,
            remoteEnabled: true,
            hostCandidates: [],
            ttlSeconds: 360
        )

        #expect(requestedPaths() == ["/v1/session/heartbeat"])
    }

    @MainActor
    @Test("Advertise creates only when heartbeat reports missing session")
    func advertiseFallsBackToCreateAfterHeartbeat404() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 404, body: ["ok": false, "error": "session_not_found"]),
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertiseHostSession(
            sessionID: "session-2",
            hostID: Self.hostID,
            remoteEnabled: true,
            hostCandidates: [],
            ttlSeconds: 360
        )

        #expect(requestedPaths() == ["/v1/session/heartbeat", "/v1/session/create"])
    }

    @MainActor
    @Test("Advertise retries heartbeat when create races with another host")
    func advertiseRetriesHeartbeatAfterCreateConflict() async throws {
        let (client, requestedPaths) = makeClient(responses: [
            .json(statusCode: 404, body: ["ok": false, "error": "session_not_found"]),
            .json(statusCode: 409, body: ["ok": false, "error": "session_exists"]),
            .json(statusCode: 200, body: ["ok": true]),
        ])

        try await client.advertiseHostSession(
            sessionID: "session-3",
            hostID: Self.hostID,
            remoteEnabled: true,
            hostCandidates: [],
            ttlSeconds: 360
        )

        #expect(
            requestedPaths() == [
                "/v1/session/heartbeat",
                "/v1/session/create",
                "/v1/session/heartbeat",
            ]
        )
    }

    @MainActor
    private func makeClient(
        responses: [MirageRemoteSignalingMockResponse]
    ) -> (MirageRemoteSignalingClient, @Sendable () -> [String]) {
        MirageRemoteSignalingMockURLProtocol.configure(responses)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MirageRemoteSignalingMockURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        let identityManager = MirageIdentityManager(
            service: "com.ethanlipnik.mirage.tests.remote-signaling.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let configuration = MirageRemoteSignalingConfiguration(
            baseURL: URL(string: "https://mirage-remote-signaling.test")!,
            requestTimeout: 5,
            appAuthentication: MirageRemoteSignalingAppAuthentication(
                appID: "test-app-id",
                sharedSecret: "test-app-secret"
            )
        )
        let client = MirageRemoteSignalingClient(
            configuration: configuration,
            identityManager: identityManager,
            urlSession: urlSession
        )
        return (client, { MirageRemoteSignalingMockURLProtocol.requestedPaths() })
    }

    private static let hostID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

private struct MirageRemoteSignalingMockResponse {
    let statusCode: Int
    let bodyData: Data

    static func json(statusCode: Int, body: [String: Any]) -> MirageRemoteSignalingMockResponse {
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        return MirageRemoteSignalingMockResponse(statusCode: statusCode, bodyData: bodyData)
    }
}

private final class MirageRemoteSignalingMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResponses: [MirageRemoteSignalingMockResponse] = []
    private var paths: [String] = []

    func configure(responses: [MirageRemoteSignalingMockResponse]) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = responses
        paths.removeAll(keepingCapacity: true)
    }

    func dequeue(path: String) -> MirageRemoteSignalingMockResponse? {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
        guard !queuedResponses.isEmpty else {
            return nil
        }
        return queuedResponses.removeFirst()
    }

    func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private final class MirageRemoteSignalingMockURLProtocol: URLProtocol {
    private static let state = MirageRemoteSignalingMockState()

    static func configure(_ responses: [MirageRemoteSignalingMockResponse]) {
        state.configure(responses: responses)
    }

    static func requestedPaths() -> [String] {
        state.requestedPaths()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response = Self.state.dequeue(path: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.bodyData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
