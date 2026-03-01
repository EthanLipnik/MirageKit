//
//  HostTrafficLightProtectionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Traffic-light cluster blocking policy decisions for remote pointer input.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Host Traffic Light Protection Policy")
struct HostTrafficLightProtectionPolicyTests {
    @Test("Fallback cluster blocks pointer events in protected area")
    func fallbackBlocksPointerInProtectedArea() {
        #expect(
            HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .leftMouseDown,
                localPoint: CGPoint(x: 12, y: 12),
                dynamicClusterSize: nil
            )
        )
    }

    @Test("Fallback cluster allows pointer events outside protected area")
    func fallbackAllowsPointerOutsideProtectedArea() {
        #expect(
            !HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .leftMouseDown,
                localPoint: CGPoint(x: 140, y: 60),
                dynamicClusterSize: nil
            )
        )
    }

    @Test("Cluster protects move and drag pointer event families")
    func clusterProtectsMoveAndDragFamilies() {
        #expect(
            HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .mouseMoved,
                localPoint: CGPoint(x: 10, y: 10),
                dynamicClusterSize: nil
            )
        )
        #expect(
            HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .rightMouseDragged,
                localPoint: CGPoint(x: 10, y: 10),
                dynamicClusterSize: nil
            )
        )
        #expect(
            HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .otherMouseUp,
                localPoint: CGPoint(x: 10, y: 10),
                dynamicClusterSize: nil
            )
        )
    }

    @Test("Non-pointer event classes are not blocked")
    func nonPointerEventClassesAreNotBlocked() {
        #expect(
            !HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .scrollWheel,
                localPoint: CGPoint(x: 10, y: 10),
                dynamicClusterSize: nil
            )
        )
    }

    @Test("Dynamic cluster metrics expand effective protected area")
    func dynamicClusterExpandsProtectedArea() {
        let dynamicClusterSize = CGSize(width: 150, height: 60)
        let effectiveSize = HostTrafficLightProtectionPolicy.effectiveClusterSize(
            dynamicClusterSize: dynamicClusterSize
        )
        #expect(effectiveSize.width == 150)
        #expect(effectiveSize.height == 60)

        #expect(
            HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .leftMouseUp,
                localPoint: CGPoint(x: 140, y: 50),
                dynamicClusterSize: dynamicClusterSize
            )
        )
        #expect(
            !HostTrafficLightProtectionPolicy.shouldBlock(
                eventType: .leftMouseUp,
                localPoint: CGPoint(x: 170, y: 70),
                dynamicClusterSize: dynamicClusterSize
            )
        )
    }
}
#endif
