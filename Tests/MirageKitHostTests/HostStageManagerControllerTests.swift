//
//  HostStageManagerControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Host Stage Manager guardrail behavior.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Stage Manager controller")
struct HostStageManagerControllerTests {
    @Test
    func parsesDefaultsValues() {
        #expect(HostStageManagerController.parseState(from: "1\n") == .enabled)
        #expect(HostStageManagerController.parseState(from: "0\n") == .disabled)
        #expect(HostStageManagerController.parseState(from: "true\n") == .enabled)
        #expect(HostStageManagerController.parseState(from: "false\n") == .disabled)
        #expect(HostStageManagerController.parseState(from: "garbage\n") == .unknown)
    }

    @Test
    func setEnabledSkipsWriteWhenAlreadyDisabled() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "0\n"),
        ])
        let controller = HostStageManagerController(commandRunner: runner.run)

        let success = await controller.setEnabled(false)
        #expect(success)

        let invocations = await runner.invocations()
        #expect(invocations.count == 1)
        #expect(invocations.first?.executablePath == "/usr/bin/defaults")
        #expect(invocations.first?.arguments == ["read", "com.apple.WindowManager", "GloballyEnabled"])
    }

    @Test
    func setEnabledDisablesAndVerifies() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "1\n"),
            Self.success(),
            Self.success(),
            Self.success(stdout: "0\n"),
        ])
        let controller = HostStageManagerController(commandRunner: runner.run)

        let success = await controller.setEnabled(false)
        #expect(success)

        let invocations = await runner.invocations()
        #expect(invocations.count == 4)
        #expect(invocations[1].arguments == ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", "false"])
        #expect(invocations[2].executablePath == "/usr/bin/killall")
        #expect(invocations[2].arguments == ["Dock"])
    }

    @Test
    func setEnabledReturnsFalseWhenWriteFails() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "1\n"),
            Self.failure(status: 1, stderr: "write failed"),
        ])
        let controller = HostStageManagerController(commandRunner: runner.run)

        let success = await controller.setEnabled(false)
        #expect(!success)

        let invocations = await runner.invocations()
        #expect(invocations.count == 2)
        #expect(invocations[1].arguments == ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", "false"])
    }

    @Test
    @MainActor
    func prepareRunsDisablePathOnlyOnceAcrossConsecutiveStarts() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "1\n"),
            Self.success(stdout: "1\n"),
            Self.success(),
            Self.success(),
            Self.success(stdout: "0\n"),
        ])
        let host = MirageHostService()
        host.stageManagerController = HostStageManagerController(commandRunner: runner.run)

        await host.prepareStageManagerForAppStreamingIfNeeded()
        await host.prepareStageManagerForAppStreamingIfNeeded()

        let invocations = await runner.invocations()
        #expect(invocations.count == 5)
        #expect(host.appStreamingStageManagerNeedsRestore)
    }

    @Test
    @MainActor
    func restoreRunsOnlyWhenMirageDisabledStageManager() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "0\n"),
        ])
        let host = MirageHostService()
        host.stageManagerController = HostStageManagerController(commandRunner: runner.run)

        await host.prepareStageManagerForAppStreamingIfNeeded()
        await host.restoreStageManagerAfterAppStreamingIfNeeded()

        let invocations = await runner.invocations()
        #expect(invocations.count == 1)
        #expect(!host.appStreamingStageManagerNeedsRestore)
    }

    @Test
    @MainActor
    func restoreRunsAfterLastAppSessionEnds() async {
        let runner = MockCommandRunner(results: [
            Self.success(stdout: "0\n"),
            Self.success(),
            Self.success(),
            Self.success(stdout: "1\n"),
        ])
        let host = MirageHostService()
        host.stageManagerController = HostStageManagerController(commandRunner: runner.run)
        host.appStreamingStageManagerNeedsRestore = true

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: "com.example.App",
            appName: "Example",
            appPath: "/Applications/Example.app",
            clientID: UUID(),
            clientName: "Client"
        )
        await host.appStreamManager.addWindowToSession(
            bundleIdentifier: "com.example.App",
            windowID: 42,
            streamID: 7,
            title: "Main",
            width: 1280,
            height: 720,
            isResizable: true
        )

        await host.removeStoppedWindowFromAppSessionIfNeeded(windowID: 42)

        let sessions = await host.appStreamManager.getAllSessions()
        #expect(sessions.isEmpty)
        #expect(!host.appStreamingStageManagerNeedsRestore)

        let invocations = await runner.invocations()
        #expect(invocations.count == 4)
        #expect(invocations[1].arguments == ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", "true"])
        #expect(invocations[2].arguments == ["Dock"])
    }
}

extension HostStageManagerControllerTests {
    struct CommandInvocation: Sendable, Equatable {
        let executablePath: String
        let arguments: [String]
    }

    actor MockCommandRunner {
        private var pendingResults: [HostStageManagerController.CommandResult]
        private var recordedInvocations: [CommandInvocation] = []

        init(results: [HostStageManagerController.CommandResult]) {
            pendingResults = results
        }

        func run(
            executablePath: String,
            arguments: [String],
            timeout _: Duration
        )
        async -> HostStageManagerController.CommandResult {
            recordedInvocations.append(CommandInvocation(executablePath: executablePath, arguments: arguments))

            if !pendingResults.isEmpty {
                return pendingResults.removeFirst()
            }

            return HostStageManagerController.CommandResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "No queued response",
                errorDescription: nil
            )
        }

        func invocations() -> [CommandInvocation] {
            recordedInvocations
        }
    }

    static func success(stdout: String = "", stderr: String = "") -> HostStageManagerController.CommandResult {
        HostStageManagerController.CommandResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: stdout,
            stderr: stderr,
            errorDescription: nil
        )
    }

    static func failure(status: Int32 = 1, stderr: String = "Failed") -> HostStageManagerController.CommandResult {
        HostStageManagerController.CommandResult(
            terminationStatus: status,
            timedOut: false,
            stdout: "",
            stderr: stderr,
            errorDescription: nil
        )
    }
}

#endif
