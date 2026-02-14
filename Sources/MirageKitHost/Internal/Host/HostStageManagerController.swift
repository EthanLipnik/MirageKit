//
//  HostStageManagerController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Stage Manager state reads and writes for host app-stream guardrails.
//

import MirageKit
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
        let stderr: String
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

    func readState() async -> State {
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
        let currentState = await readState()
        if currentState == targetState { return true }

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
            let observedState = await readState()
            if observedState == targetState { return true }
            if attempt + 1 < attempts { try? await Task.sleep(for: pollInterval) }
        }
        return false
    }

    nonisolated static func parseState(from output: String) -> State {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown }

        let token = normalized
            .split(whereSeparator: { $0.isWhitespace || $0 == ";" })
            .first
            .map(String.init) ?? normalized

        switch token {
        case "1", "true", "yes", "on":
            return .enabled
        case "0", "false", "no", "off":
            return .disabled
        default:
            return .unknown
        }
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
                stderr: "",
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
        let stderrData = await stderrTask.value

        return CommandResult(
            terminationStatus: exit.terminationStatus,
            timedOut: exit.timedOut,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
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
        try? await Task.sleep(for: .milliseconds(250))

        guard process.isRunning else { return }
        let processID = process.processIdentifier
        kill(processID, SIGKILL)
    }
}

#endif
