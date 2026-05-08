//
//  CGVirtualDisplayBridgeDiagnosticsTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 3/7/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

@Suite("CGVirtualDisplayBridge Diagnostics", .serialized)
struct CGVirtualDisplayBridgeDiagnosticsTests {

    @Test("Cached descriptor profile is evicted immediately after failure")
    func cachedDescriptorProfileEvictionDecision() {
        let failedAttempt = CGVirtualDisplayBridge.DescriptorAttempt(
            profile: .persistentGlobalQueue,
            serial: 42,
            queue: .global(qos: .userInteractive),
            label: "persistent-global-queue"
        )
        let cachedHint = CGVirtualDisplayBridge.CachedValidationHint(
            profile: .persistentGlobalQueue,
            serial: 42,
            coverageStatus: .strictCanonical
        )

        #expect(
            CGVirtualDisplayBridge.shouldEvictCachedDescriptorProfile(
                failedAttempt: failedAttempt,
                preferredProfile: .persistentGlobalQueue,
                cachedHint: cachedHint
            )
        )
    }

    @Test("Cached descriptor profile is tried first for an exact mode")
    func cachedDescriptorProfileIsTriedFirst() {
        CGVirtualDisplayBridge.clearPreferredDescriptorProfile(
            for: .displayP3,
            width: 6016,
            height: 3376,
            refreshRate: 60,
            hiDPI: true
        )
        defer {
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(
                for: .displayP3,
                width: 6016,
                height: 3376,
                refreshRate: 60,
                hiDPI: true
            )
        }

        CGVirtualDisplayBridge.storePreferredDescriptorProfile(
            .serial0GlobalQueue,
            for: .displayP3,
            width: 6016,
            height: 3376,
            refreshRate: 60,
            hiDPI: true
        )

        let attempts = CGVirtualDisplayBridge.descriptorAttempts(
            persistentSerial: 99,
            hiDPI: true,
            colorSpace: .displayP3,
            width: 6016,
            height: 3376,
            refreshRate: 60,
            cachedHint: nil
        )

        #expect(attempts.first?.profile == .serial0GlobalQueue)
    }

    @Test("Invalidating all persistent serials rotates serials and clears cached descriptor profiles")
    func invalidatingAllPersistentSerialsRotatesSerialsAndClearsCachedProfiles() {
        CGVirtualDisplayBridge.storePreferredDescriptorProfile(
            .serial0GlobalQueue,
            for: .displayP3,
            width: 5120,
            height: 2880,
            refreshRate: 60,
            hiDPI: true
        )
        let p3Serial = CGVirtualDisplayBridge.persistentSerialNumber(for: .displayP3)
        let sRGBSerial = CGVirtualDisplayBridge.persistentSerialNumber(for: .sRGB)
        defer {
            CGVirtualDisplayBridge.invalidateAllPersistentSerials()
            CGVirtualDisplayBridge.clearPreferredDescriptorProfile(
                for: .displayP3,
                width: 5120,
                height: 2880,
                refreshRate: 60,
                hiDPI: true
            )
        }

        CGVirtualDisplayBridge.invalidateAllPersistentSerials()

        #expect(CGVirtualDisplayBridge.persistentSerialNumber(for: .displayP3) != p3Serial)
        #expect(CGVirtualDisplayBridge.persistentSerialNumber(for: .sRGB) != sRGBSerial)

        let attempts = CGVirtualDisplayBridge.descriptorAttempts(
            persistentSerial: CGVirtualDisplayBridge.persistentSerialNumber(for: .displayP3),
            hiDPI: true,
            colorSpace: .displayP3,
            width: 5120,
            height: 2880,
            refreshRate: 60,
            cachedHint: nil
        )
        #expect(attempts.first?.profile != .serial0GlobalQueue)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor CGVirtualDisplayBridgeTestSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []
    private var errors: [LoomDiagnosticsErrorEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event)
    }

    func logCount() -> Int {
        logs.count
    }

    func bridgeErrorCount() -> Int {
        errors.filter { Self.isBridgeError($0) }.count
    }

    func logMessages() -> [String] {
        logs.map(\.message)
    }

    func firstBridgeError() -> LoomDiagnosticsErrorEvent? {
        errors.first(where: Self.isBridgeError)
    }

    private static func isBridgeError(_ event: LoomDiagnosticsErrorEvent) -> Bool {
        event.fileID.contains("CGVirtualDisplayBridge.swift")
    }
}
#endif
