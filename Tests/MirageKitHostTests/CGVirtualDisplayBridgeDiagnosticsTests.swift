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
    @Test("Descriptor configuration leaves colorimetry to WindowServer")
    func descriptorConfigurationLeavesColorimetryToWindowServer() {
        let descriptor = RecordingDescriptor()
        let attempt = CGVirtualDisplayBridge.DescriptorAttempt(
            profile: .persistentGlobalQueue,
            serial: 42,
            queue: .global(qos: .userInteractive),
            label: "persistent-global-queue"
        )

        CGVirtualDisplayBridge.configureDescriptor(
            descriptor,
            name: "Mirage Test Display",
            width: 2752,
            height: 2064,
            ppi: 220,
            hiDPI: true,
            profile: attempt
        )

        #expect(descriptor.recordedKeys.contains("name"))
        #expect(descriptor.recordedKeys.contains("serialNum"))
        #expect(descriptor.recordedKeys.contains("queue"))
        #expect(!descriptor.recordedKeys.contains("redPrimary"))
        #expect(!descriptor.recordedKeys.contains("greenPrimary"))
        #expect(!descriptor.recordedKeys.contains("bluePrimary"))
        #expect(!descriptor.recordedKeys.contains("whitePoint"))
    }

    @Test("Non-Retina descriptor advertises enough native pixels for full-size 1x modes")
    func nonRetinaDescriptorAdvertisesEnoughNativePixelsForFullSizeOneXModes() {
        let oneX = CGVirtualDisplayBridge.descriptorNativePixelSize(
            width: 1600,
            height: 1200,
            hiDPI: false
        )
        let retina = CGVirtualDisplayBridge.descriptorNativePixelSize(
            width: 3200,
            height: 2400,
            hiDPI: true
        )

        #expect(oneX.width == 3200)
        #expect(oneX.height == 2400)
        #expect(retina.width == 3200)
        #expect(retina.height == 2400)
    }

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
            serial: 42
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
            .persistentMainQueue,
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

        #expect(attempts.first?.profile == .persistentMainQueue)
        #expect(attempts.first?.serial == 99)
    }

    @Test("Invalidating all persistent serials rotates serials and clears cached descriptor profiles")
    func invalidatingAllPersistentSerialsRotatesSerialsAndClearsCachedProfiles() {
        CGVirtualDisplayBridge.storePreferredDescriptorProfile(
            .persistentMainQueue,
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
        #expect(attempts.allSatisfy { $0.serial != 0 })
    }

    @Test("Descriptor attempts ignore zero serial cached hints")
    func descriptorAttemptsIgnoreZeroSerialCachedHints() {
        let attempts = CGVirtualDisplayBridge.descriptorAttempts(
            persistentSerial: 123,
            hiDPI: true,
            colorSpace: .sRGB,
            width: 2752,
            height: 2064,
            refreshRate: 60,
            cachedHint: CGVirtualDisplayBridge.CachedValidationHint(
                profile: .persistentGlobalQueue,
                serial: 0
            )
        )

        #expect(!attempts.isEmpty)
        #expect(attempts.allSatisfy { $0.serial == 123 })
    }

    @Test("Stale persistent serial rotates before descriptor attempts")
    func stalePersistentSerialRotatesBeforeDescriptorAttempts() {
        let originalSerial = CGVirtualDisplayBridge.persistentSerialNumber(for: .sRGB)
        defer {
            if CGVirtualDisplayBridge.persistentSerialNumber(for: .sRGB) != originalSerial {
                CGVirtualDisplayBridge.invalidatePersistentSerial(for: .sRGB)
            }
        }

        let attempts = CGVirtualDisplayBridge.descriptorAttempts(
            persistentSerial: originalSerial,
            hiDPI: true,
            colorSpace: .sRGB,
            width: 2752,
            height: 2064,
            refreshRate: 60,
            cachedHint: CGVirtualDisplayBridge.CachedValidationHint(
                profile: .persistentGlobalQueue,
                serial: originalSerial
            ),
            isSerialOnline: { $0 == originalSerial }
        )

        #expect(!attempts.isEmpty)
        #expect(attempts.allSatisfy { $0.serial != 0 })
        #expect(attempts.allSatisfy { $0.serial != originalSerial })
        #expect(attempts.first?.profile == .persistentGlobalQueue)
    }
}

private final class RecordingDescriptor: NSObject {
    private(set) var recordedKeys = Set<String>()

    override func setValue(_ value: Any?, forUndefinedKey key: String) {
        recordedKeys.insert(key)
    }
}
#endif
