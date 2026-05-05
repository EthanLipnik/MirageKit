//
//  BetterDisplaySoftwareBrightnessControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

#if os(macOS)
import CoreGraphics
@testable import MirageKitHost
import Testing

@Suite("BetterDisplay software brightness controller")
struct BetterDisplaySoftwareBrightnessControllerTests {
    @Test
    func snapshotsAndDimsTargetDisplays() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "0.42\n"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101], dimmed: true)

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["set", "-displayID=101", "-softwareBrightness=0.000000"],
        ])
    }

    @Test
    func restoresSnapshotsOnDeactivate() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "softwareBrightness: 75%"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101], dimmed: true)
        await controller.restoreAll()

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["set", "-displayID=101", "-softwareBrightness=0.000000"],
            ["set", "-displayID=101", "-softwareBrightness=0.750000"],
        ])
    }

    @Test
    func restoresDisplaysRemovedFromTarget() async {
        let runner = BetterDisplayCommandRecorder(getValues: [
            101: "0.4",
            202: "0.8",
        ])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101, 202], dimmed: true)
        await controller.updateTarget(displayIDs: [202], dimmed: true)

        let commands = await runner.commands
        #expect(commands.contains(["set", "-displayID=101", "-softwareBrightness=0.400000"]))
    }

    @Test
    func skipsMissingOrInvalidBetterDisplayValues() async {
        let runner = BetterDisplayCommandRecorder(getValues: [
            101: "not available",
            202: "0.8",
        ])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101, 202], dimmed: true)

        let commands = await runner.commands
        #expect(commands.contains(["get", "-displayID=101", "-softwareBrightness"]))
        #expect(!commands.contains(["set", "-displayID=101", "-softwareBrightness=0.000000"]))
        #expect(commands.contains(["set", "-displayID=202", "-softwareBrightness=0.000000"]))
    }

    @Test
    func silentlySkipsWhenExecutableIsUnavailable() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "0.5"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in false },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101], dimmed: true)
        await controller.restoreAll()

        #expect(await runner.commands.isEmpty)
    }

    @Test
    func revealRestoreKeepsSnapshotsForRedim() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "0.5"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.updateTarget(displayIDs: [101], dimmed: true)
        await controller.restoreKnownDisplays()
        await controller.dimKnownDisplays()

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["set", "-displayID=101", "-softwareBrightness=0.000000"],
            ["set", "-displayID=101", "-softwareBrightness=0.500000"],
            ["set", "-displayID=101", "-softwareBrightness=0.000000"],
        ])
    }

}

private actor BetterDisplayCommandRecorder {
    private let getValues: [CGDirectDisplayID: String]
    private(set) var commands: [[String]] = []

    init(getValues: [CGDirectDisplayID: String]) {
        self.getValues = getValues
    }

    func run(
        executablePath: String,
        arguments: [String]
    ) async throws -> BetterDisplaySoftwareBrightnessController.CommandResult {
        commands.append(arguments)

        guard arguments.first == "get",
              let displayIDArgument = arguments.first(where: { $0.hasPrefix("-displayID=") }),
              let displayID = CGDirectDisplayID(String(displayIDArgument.dropFirst("-displayID=".count))),
              let value = getValues[displayID] else {
            return BetterDisplaySoftwareBrightnessController.CommandResult(
                terminationStatus: 0,
                standardOutput: ""
            )
        }

        return BetterDisplaySoftwareBrightnessController.CommandResult(
            terminationStatus: 0,
            standardOutput: value
        )
    }
}
#endif
