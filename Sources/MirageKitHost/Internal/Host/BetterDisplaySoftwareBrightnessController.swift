//
//  BetterDisplaySoftwareBrightnessController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreGraphics
import Foundation

#if os(macOS)
actor BetterDisplaySoftwareBrightnessController {
    struct CommandResult: Sendable {
        let terminationStatus: Int32
        let standardOutput: String
    }

    typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) async throws -> CommandResult
    typealias ExecutableAvailability = @Sendable (_ executablePath: String) -> Bool

    static let defaultExecutablePath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    private let executablePath: String
    private let isExecutableAvailable: ExecutableAvailability
    private let commandRunner: CommandRunner

    private static let restoredBrightness = 1.0
    private static let staleDimmedBrightnessThreshold = 0.01

    init(
        executablePath: String = BetterDisplaySoftwareBrightnessController.defaultExecutablePath,
        isExecutableAvailable: @escaping ExecutableAvailability = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        commandRunner: @escaping CommandRunner = BetterDisplaySoftwareBrightnessController.runCommand
    ) {
        self.executablePath = executablePath
        self.isExecutableAvailable = isExecutableAvailable
        self.commandRunner = commandRunner
    }

    nonisolated static func isDefaultExecutableAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: defaultExecutablePath)
    }

    func restoreStaleDimmedDisplays(displayIDs: Set<CGDirectDisplayID>) async {
        guard isExecutableAvailable(executablePath) else { return }
        for displayID in displayIDs.sorted() {
            guard let brightness = await readSoftwareBrightness(displayID: displayID),
                  Self.shouldRestoreStaleDimmedBrightness(brightness) else {
                continue
            }
            await setSoftwareBrightness(Self.restoredBrightness, displayID: displayID)
        }
    }

    private func readSoftwareBrightness(displayID: CGDirectDisplayID) async -> Double? {
        guard let result = try? await commandRunner(
            executablePath,
            ["get", "-displayID=\(displayID)", "-softwareBrightness"]
        ),
            result.terminationStatus == 0 else {
            return nil
        }

        return Self.parseBrightnessValue(result.standardOutput)
    }

    private func setSoftwareBrightness(_ brightness: Double, displayID: CGDirectDisplayID) async {
        let clampedBrightness = min(1, max(0, brightness))
        _ = try? await commandRunner(
            executablePath,
            [
                "set",
                "-displayID=\(displayID)",
                "-softwareBrightness=\(Self.formatBrightness(clampedBrightness))",
            ]
        )
    }

    static func parseBrightnessValue(_ output: String) -> Double? {
        let normalizedOutput = output
            .replacingOccurrences(of: "%", with: " % ")
            .replacingOccurrences(of: "=", with: " ")
            .replacingOccurrences(of: ":", with: " ")

        for token in normalizedOutput.components(separatedBy: .whitespacesAndNewlines) {
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { continue }
            if let value = Double(trimmed) {
                return value > 1 ? value / 100 : value
            }
        }

        return nil
    }

    static func shouldRestoreStaleDimmedBrightness(_ brightness: Double) -> Bool {
        brightness <= staleDimmedBrightnessThreshold
    }

    private static func formatBrightness(_ brightness: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), brightness)
    }

    private static func runCommand(executablePath: String, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8) ?? ""
        )
    }
}
#endif
