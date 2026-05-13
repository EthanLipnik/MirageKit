//
//  UnlockManager+CredentialVerification.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Darwin
import Foundation
import MirageKit

#if os(macOS)

extension UnlockManager {
    enum CredentialVerificationResult: Equatable {
        case valid
        case invalid
        case timedOut
        case failedToRun(String)
    }

    func verifyCredentialsViaAuthorization(
        username: String,
        password: String,
        timeout: Duration = .seconds(8)
    ) async -> CredentialVerificationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = ["/Local/Default", "-authonly", username, password]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to run dscl: ")
            return .failedToRun(error.localizedDescription)
        }

        let result = await waitForProcessExitOrTimeout(process, timeout: timeout)
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.timedOut {
            MirageLogger.error(.host, "dscl auth timed out after \(timeout)")
            return .timedOut
        }

        if result.status == 0 {
            return .valid
        }

        if let errorOutput, !errorOutput.isEmpty {
            MirageLogger.error(.host, "dscl auth failed: \(errorOutput)")
        } else {
            MirageLogger.error(.host, "dscl auth failed with status \(result.status)")
        }
        return .invalid
    }

    private func waitForProcessExitOrTimeout(
        _ process: Process,
        timeout: Duration
    ) async -> (status: Int32, timedOut: Bool) {
        let timeoutTask = Task<Bool, Never> { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            guard !Task.isCancelled else { return false }
            guard process.isRunning else { return false }
            await self?.terminateProcess(process)
            return true
        }

        let status = await waitForProcessExit(process)
        timeoutTask.cancel()
        let didTimeout = await timeoutTask.value
        return (status, didTimeout)
    }

    private func waitForProcessExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }

            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
    }

    private func terminateProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

#endif
