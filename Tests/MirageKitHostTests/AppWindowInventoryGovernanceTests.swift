//
//  AppWindowInventoryGovernanceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App-window slot cap, inventory, swap-map, and shared-bitrate governance tests.
//

@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Network
import Testing

#if os(macOS)
@Suite("App Window Inventory Governance")
struct AppWindowInventoryGovernanceTests {
    private let bundleIdentifier = "com.example.InventoryApp"

    @Test("Frame-rate throttling is disabled for all app sessions")
    func frameRateThrottlePolicyIsDisabled() {
        #expect(!MirageHostService.shouldThrottleAppStreamFrameRate(maxVisibleSlots: 1))
        #expect(!MirageHostService.shouldThrottleAppStreamFrameRate(maxVisibleSlots: 2))
        #expect(!MirageHostService.shouldThrottleAppStreamFrameRate(maxVisibleSlots: 8))
    }

    @Test("Free-tier cap keeps one visible slot and moves overflow into hidden inventory")
    func freeTierCapMovesOverflowIntoHiddenInventory() async {
        let manager = AppStreamManager()
        _ = await manager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 1,
            bitrateBudgetBps: 12_000_000
        )

        let firstSlot = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 101,
            streamID: 1,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        let overflowSlot = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 102,
            streamID: 2,
            title: "Overflow",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await manager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: 102,
            title: "Overflow",
            width: 1200,
            height: 800,
            isResizable: true
        )

        #expect(firstSlot == 0)
        #expect(overflowSlot == nil)
        let hasVisibleCapacity = await manager.hasVisibleSlotCapacity(bundleIdentifier: bundleIdentifier)
        #expect(!hasVisibleCapacity)

        guard let inventory = await manager.inventoryMessage(bundleIdentifier: bundleIdentifier) else {
            Issue.record("Expected app-window inventory message")
            return
        }

        #expect(inventory.maxVisibleSlots == 1)
        #expect(inventory.slots.count == 1)
        #expect(inventory.slots[0].window.windowID == 101)
        #expect(inventory.hiddenWindows.map(\.windowID) == [102])
    }

    @Test("Pro-tier cap keeps eight visible slots and leaves ninth window hidden")
    func proTierCapKeepsEightVisibleSlots() async {
        let manager = AppStreamManager()
        _ = await manager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 8,
            bitrateBudgetBps: 80_000_000
        )

        for index in 0 ..< 8 {
            let assignedSlot = await manager.addWindowToSession(
                bundleIdentifier: bundleIdentifier,
                windowID: WindowID(200 + index),
                streamID: StreamID(index + 1),
                title: "Window \(index + 1)",
                width: 1200,
                height: 800,
                isResizable: true
            )
            #expect(assignedSlot == index)
        }

        let overflowSlot = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 299,
            streamID: 99,
            title: "Overflow",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await manager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: 299,
            title: "Overflow",
            width: 1200,
            height: 800,
            isResizable: true
        )

        #expect(overflowSlot == nil)

        guard let inventory = await manager.inventoryMessage(bundleIdentifier: bundleIdentifier) else {
            Issue.record("Expected app-window inventory message")
            return
        }

        #expect(inventory.maxVisibleSlots == 8)
        #expect(inventory.slots.count == 8)
        #expect(Set(inventory.slots.map(\.slotIndex)) == Set(0 ..< 8))
        #expect(inventory.hiddenWindows.map(\.windowID) == [299])
    }

    @Test("Slot rebind keeps stream-to-slot mapping and removes hidden source window")
    func slotRebindKeepsStreamSlotMapping() async {
        let manager = AppStreamManager()
        _ = await manager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: 30_000_000
        )

        _ = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 301,
            streamID: 41,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 302,
            streamID: 42,
            title: "Display 2",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await manager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: 303,
            title: "Hidden",
            width: 1200,
            height: 800,
            isResizable: true
        )

        let replaced = await manager.replaceVisibleWindowForStream(
            bundleIdentifier: bundleIdentifier,
            streamID: 41,
            newWindowID: 303,
            title: "Hidden",
            width: 1200,
            height: 800,
            isResizable: true
        )

        #expect(replaced?.oldWindowID == 301)
        #expect(replaced?.slotIndex == 0)
        let reboundWindowID = await manager.windowIDForStream(bundleIdentifier: bundleIdentifier, streamID: 41)
        let reboundStreamID = await manager.streamIDForWindow(bundleIdentifier: bundleIdentifier, windowID: 303)
        let staleWindowStreamID = await manager.streamIDForWindow(bundleIdentifier: bundleIdentifier, windowID: 301)
        #expect(reboundWindowID == 303)
        #expect(reboundStreamID == 41)
        #expect(staleWindowStreamID == nil)

        guard let inventory = await manager.inventoryMessage(bundleIdentifier: bundleIdentifier) else {
            Issue.record("Expected app-window inventory message")
            return
        }
        #expect(!inventory.hiddenWindows.contains(where: { $0.windowID == 303 }))
    }

    @Test("Visible window cannot be rebound to a different stream ID")
    func duplicateWindowBindingIsRejected() async {
        let manager = AppStreamManager()
        _ = await manager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: 30_000_000
        )

        let firstSlot = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 350,
            streamID: 71,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        let duplicateSlot = await manager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 350,
            streamID: 72,
            title: "Duplicate",
            width: 1200,
            height: 800,
            isResizable: true
        )

        #expect(firstSlot == 0)
        #expect(duplicateSlot == nil)
        #expect(await manager.streamIDForWindow(bundleIdentifier: bundleIdentifier, windowID: 350) == 71)
        #expect(await manager.windowIDForStream(bundleIdentifier: bundleIdentifier, streamID: 72) == nil)

        guard let inventory = await manager.inventoryMessage(bundleIdentifier: bundleIdentifier) else {
            Issue.record("Expected app-window inventory message")
            return
        }
        #expect(inventory.slots.count == 1)
        #expect(inventory.slots[0].streamID == 71)
    }

    @MainActor
    @Test("Shared bitrate targets stay within session budget")
    func sharedBitrateTargetsStayWithinBudget() async {
        let budget = 60_000_000
        let host = MirageHostService(hostName: "BitrateHost")

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: budget
        )

        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 401,
            streamID: 61,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 402,
            streamID: 62,
            title: "Display 2",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await host.appStreamManager.upsertHiddenWindow(
            bundleIdentifier: bundleIdentifier,
            windowID: 403,
            title: "Hidden",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 61,
            isActive: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 62,
            isActive: false
        )

        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "test")
        let targets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)

        #expect(targets.count == 2)
        #expect((targets[61] ?? 0) >= (targets[62] ?? 0))
        let allocatedTotal = targets.values.reduce(0, +)
        #expect(allocatedTotal <= budget)
    }

    @MainActor
    @Test("Split-evenly policy keeps equal targets despite activity")
    func splitEvenlyPolicyKeepsEqualTargets() async {
        let budget = 60_000_000
        let host = MirageHostService(hostName: "BitrateHost")

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: budget,
            bitrateAllocationPolicy: .splitEvenly
        )

        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 501,
            streamID: 81,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 502,
            streamID: 82,
            title: "Secondary",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 81,
            isActive: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 82,
            isActive: false
        )

        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "test")
        let targets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)

        #expect(targets.count == 2)
        #expect(targets[81] == targets[82])
        let allocatedTotal = targets.values.reduce(0, +)
        #expect(allocatedTotal <= budget)
    }

    @MainActor
    @Test("Prioritize-active policy keeps one dominant target without active signals")
    func prioritizePolicyKeepsDominantTargetWithoutSignals() async {
        let budget = 60_000_000
        let host = MirageHostService(hostName: "BitrateHost")

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: budget,
            bitrateAllocationPolicy: .prioritizeActiveWindow
        )

        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 601,
            streamID: 91,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 602,
            streamID: 92,
            title: "Secondary",
            width: 1200,
            height: 800,
            isResizable: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 91,
            isActive: false
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 92,
            isActive: false
        )

        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "test")
        let targets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)

        #expect(targets.count == 2)
        #expect((targets[91] ?? 0) != (targets[92] ?? 0))
        let allocatedTotal = targets.values.reduce(0, +)
        #expect(allocatedTotal <= budget)
    }

    @MainActor
    @Test("Prioritize-active policy keeps dominant stream sticky while both streams are active")
    func prioritizePolicyKeepsDominantStreamSticky() async {
        let budget = 25_000_000
        let host = MirageHostService(hostName: "BitrateHost")

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: budget,
            bitrateAllocationPolicy: .prioritizeActiveWindow
        )

        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 651,
            streamID: 93,
            title: "Primary",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 652,
            streamID: 94,
            title: "Secondary",
            width: 1200,
            height: 800,
            isResizable: true
        )

        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 93,
            isActive: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 94,
            isActive: false
        )
        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "initial")

        let initialTargets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)
        #expect((initialTargets[93] ?? 0) > (initialTargets[94] ?? 0))

        host.appStreamFrontmostSignalByStreamID[93] = false
        host.appStreamFrontmostSignalByStreamID[94] = true
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 93,
            isActive: true
        )
        await host.appStreamManager.markStreamActivity(
            bundleIdentifier: bundleIdentifier,
            streamID: 94,
            isActive: true
        )
        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "frontmost-shift")

        let stickyTargets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)
        #expect((stickyTargets[93] ?? 0) > (stickyTargets[94] ?? 0))
    }

    @MainActor
    @Test("Multi-window targets enforce per-stream cap")
    func multiWindowTargetsEnforcePerStreamCap() async {
        let budget = 300_000_000
        let host = MirageHostService(hostName: "BitrateHost")

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: UUID(),
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: budget,
            bitrateAllocationPolicy: .splitEvenly
        )

        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 701,
            streamID: 101,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 702,
            streamID: 102,
            title: "Secondary",
            width: 1200,
            height: 800,
            isResizable: true
        )

        await host.recomputeAppSessionBitrateBudget(bundleIdentifier: bundleIdentifier, reason: "test")
        let targets = await host.appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)

        #expect(targets.count == 2)
        #expect((targets[101] ?? 0) <= MirageHostService.multiWindowPerStreamBitrateCapBps)
        #expect((targets[102] ?? 0) <= MirageHostService.multiWindowPerStreamBitrateCapBps)
        #expect(targets[101] == targets[102])
    }

    @MainActor
    @Test("App-stream stop message no longer ends the full app session")
    func appStreamStopMessageDoesNotEndFullSession() async throws {
        let host = MirageHostService(hostName: "StopSemanticsHost")
        let clientID = UUID()
        let client = MirageConnectedClient(
            id: clientID,
            name: "Client",
            deviceType: .mac,
            connectedAt: Date()
        )
        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleIdentifier,
            appName: "InventoryApp",
            appPath: "/Applications/InventoryApp.app",
            clientID: clientID,
            clientName: client.name,
            requestedDisplayResolution: CGSize(width: 1920, height: 1080),
            requestedClientScaleFactor: 2.0,
            maxVisibleSlots: 2,
            bitrateBudgetBps: 30_000_000
        )
        await host.appStreamManager.markSessionStreaming(bundleIdentifier)
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleIdentifier,
            windowID: 9201,
            streamID: 77,
            title: "Main",
            width: 1200,
            height: 800,
            isResizable: true
        )

        host.registerControlMessageHandlers()
        let stop = StopStreamMessage(streamID: 77, minimizeWindow: false)
        let message = try ControlMessage(type: .stopStream, content: stop)
        let connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: .init(rawValue: 9)!),
            using: .tcp
        )

        await host.handleClientMessage(message, from: client, connection: connection)

        let remainingSession = await host.appStreamManager.getSession(bundleIdentifier: bundleIdentifier)
        #expect(remainingSession != nil)
    }
}
#endif
