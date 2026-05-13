//
//  HostAppListRequestDeferralTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Interactive workload deferral coverage for host app-list requests.
//

@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Host App List Request Deferral")
struct HostAppListRequestDeferralTests {
    @MainActor
    @Test("Cancelling app-list work invalidates stale progress batches")
    func cancellationInvalidatesStaleProgressBatches() async {
        let service = MirageHostService(hostName: "Test Host", deviceID: UUID())
        let clientID = UUID()
        service.pendingAppListRequest = MirageHostService.PendingAppListRequest(
            clientID: clientID,
            requestID: UUID(),
            requestedForceRefresh: true,
            forceIconReset: false,
            priorityBundleIdentifiers: [],
            knownIconBundleIdentifiers: []
        )
        let originalToken = service.appListRequestToken
        service.appListRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
        }

        service.cancelAppListRequestForInteractiveWorkload(logCancellation: false)

        #expect(service.pendingAppListRequest?.clientID == clientID)
        #expect(service.appListRequestTask == nil)
        #expect(service.appListRequestToken != originalToken)
    }
}
#endif
