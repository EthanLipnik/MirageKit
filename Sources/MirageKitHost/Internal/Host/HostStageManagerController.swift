//
//  HostStageManagerController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Stage Manager state reads and writes for host app-stream guardrails.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)

import Darwin
import Foundation

actor HostStageManagerController {
    enum State: Equatable, Sendable {
        case enabled
        case disabled
        case unknown
    }

    struct CommandResult: Sendable {
        let terminationStatus: Int32?
        let timedOut: Bool
        let stdout: String
        let errorDescription: String?

        var succeeded: Bool {
            !timedOut && terminationStatus == 0 && errorDescription == nil
        }
    }

    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String], _ timeout: Duration) async -> CommandResult

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = HostStageManagerController.runCommand) {
        self.commandRunner = commandRunner
    }

    /// Reads the current Stage Manager setting from the WindowManager defaults domain.
    func readCurrentState() async -> State {
        let result = await commandRunner(
            "/usr/bin/defaults",
            ["read", "com.apple.WindowManager", "GloballyEnabled"],
            .seconds(2)
        )
        guard result.succeeded else { return .unknown }
        return Self.parseState(from: result.stdout)
    }

    func setEnabled(
        _ enabled: Bool,
        verifyAttempts: Int = 12,
        pollInterval: Duration = .milliseconds(120)
    )
    async -> Bool {
        let targetState: State = enabled ? .enabled : .disabled
        let initialState = await readCurrentState()
        if initialState == targetState { return true }

        let boolValue = enabled ? "true" : "false"
        let writeResult = await commandRunner(
            "/usr/bin/defaults",
            ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", boolValue],
            .seconds(2)
        )
        guard writeResult.succeeded else { return false }

        let restartResult = await commandRunner(
            "/usr/bin/killall",
            ["Dock"],
            .seconds(2)
        )
        guard restartResult.succeeded else { return false }

        let attempts = max(1, verifyAttempts)
        for attempt in 0 ..< attempts {
            let observedState = await readCurrentState()
            if observedState == targetState { return true }
            if attempt + 1 < attempts {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return false
                }
            }
        }
        return false
    }

    nonisolated static func parseState(from output: String) -> State {
        guard let enabled = MirageEnvironmentValue.boolean(output) else { return .unknown }
        return enabled ? .enabled : .disabled
    }

    nonisolated private static func runCommand(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    )
    async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                terminationStatus: nil,
                timedOut: false,
                stdout: "",
                errorDescription: error.localizedDescription
            )
        }

        let stdoutTask = Task.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let exit = await waitForProcessExitOrTimeout(process, timeout: timeout)
        let stdoutData = await stdoutTask.value
        _ = await stderrTask.value

        return CommandResult(
            terminationStatus: exit.terminationStatus,
            timedOut: exit.timedOut,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            errorDescription: nil
        )
    }

    nonisolated private static func waitForProcessExitOrTimeout(
        _ process: Process,
        timeout: Duration
    )
    async -> (terminationStatus: Int32?, timedOut: Bool) {
        let timeoutTask = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }

            guard !Task.isCancelled else { return false }
            guard process.isRunning else { return false }

            await terminateProcess(process)
            return true
        }

        let terminationStatus = await waitForProcessExit(process)
        timeoutTask.cancel()
        let didTimeout = await timeoutTask.value

        return (terminationStatus, didTimeout)
    }

    nonisolated private static func waitForProcessExit(_ process: Process) async -> Int32? {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }

            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
        }
    }

    nonisolated private static func terminateProcess(_ process: Process) async {
        guard process.isRunning else { return }

        process.terminate()
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }

        guard process.isRunning else { return }
        let processID = process.processIdentifier
        kill(processID, SIGKILL)
    }
}

#endif
