//
//  MirageRemoteSignalingSecurityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Security validation coverage for remote signaling configuration.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Remote Signaling Security")
struct MirageRemoteSignalingSecurityTests {
    @MainActor
    @Test("Remote signaling rejects non-HTTPS base URL")
    func remoteSignalingRejectsNonHTTPSBaseURL() async {
        let configuration = MirageRemoteSignalingConfiguration(
            baseURL: URL(string: "http://example.com")!,
            appAuthentication: MirageRemoteSignalingAppAuthentication(
                appID: "test-app",
                sharedSecret: "test-secret"
            )
        )
        let client = MirageRemoteSignalingClient(configuration: configuration)

        do {
            try await client.joinSession(sessionID: "session-1")
            Issue.record("Expected invalidConfiguration for non-HTTPS signaling URL.")
        } catch let error as MirageRemoteSignalingError {
            switch error {
            case .invalidConfiguration:
                break
            default:
                Issue.record("Expected invalidConfiguration, got \(error.localizedDescription).")
            }
        } catch {
            Issue.record("Expected MirageRemoteSignalingError, got \(error.localizedDescription).")
        }
    }
}
