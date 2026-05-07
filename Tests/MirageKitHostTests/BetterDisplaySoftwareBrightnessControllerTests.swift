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
    func restoresStaleZeroSoftwareBrightness() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "0.0\n"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.restoreStaleDimmedDisplays(displayIDs: [101])

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["set", "-displayID=101", "-softwareBrightness=1.000000"],
        ])
    }

    @Test
    func restoresOnlyStaleDimmedTargetDisplays() async {
        let runner = BetterDisplayCommandRecorder(getValues: [
            101: "0.0",
            202: "softwareBrightness: 75%",
        ])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.restoreStaleDimmedDisplays(displayIDs: [202, 101])

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["set", "-displayID=101", "-softwareBrightness=1.000000"],
            ["get", "-displayID=202", "-softwareBrightness"],
        ])
    }

    @Test
    func silentlySkipsWhenExecutableIsUnavailable() async {
        let runner = BetterDisplayCommandRecorder(getValues: [101: "0.0"])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in false },
            commandRunner: runner.run
        )

        await controller.restoreStaleDimmedDisplays(displayIDs: [101])

        #expect(await runner.commands.isEmpty)
    }

    @Test
    func skipsMissingOrInvalidBetterDisplayValues() async {
        let runner = BetterDisplayCommandRecorder(getValues: [
            101: "not available",
            202: "0.0",
        ])
        let controller = BetterDisplaySoftwareBrightnessController(
            executablePath: "/tmp/BetterDisplay",
            isExecutableAvailable: { _ in true },
            commandRunner: runner.run
        )

        await controller.restoreStaleDimmedDisplays(displayIDs: [101, 202])

        let commands = await runner.commands
        #expect(commands == [
            ["get", "-displayID=101", "-softwareBrightness"],
            ["get", "-displayID=202", "-softwareBrightness"],
            ["set", "-displayID=202", "-softwareBrightness=1.000000"],
        ])
    }

    @Test
    func staleBrightnessThresholdAllowsNearZeroOnly() {
        #expect(BetterDisplaySoftwareBrightnessController.shouldRestoreStaleDimmedBrightness(0))
        #expect(BetterDisplaySoftwareBrightnessController.shouldRestoreStaleDimmedBrightness(0.01))
        #expect(!BetterDisplaySoftwareBrightnessController.shouldRestoreStaleDimmedBrightness(0.011))
        #expect(!BetterDisplaySoftwareBrightnessController.shouldRestoreStaleDimmedBrightness(0.5))
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
