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

    private static let defaultExecutablePath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    private let executablePath: String
    private let isExecutableAvailable: ExecutableAvailability
    private let commandRunner: CommandRunner
    private var snapshots: [CGDirectDisplayID: Double] = [:]

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

    func updateTarget(displayIDs: Set<CGDirectDisplayID>, dimmed: Bool) async {
        guard isExecutableAvailable(executablePath) else {
            snapshots.removeAll()
            return
        }

        let removedDisplayIDs = Set(snapshots.keys).subtracting(displayIDs)
        for displayID in removedDisplayIDs {
            await restoreAndRemove(displayID: displayID)
        }

        for displayID in displayIDs where snapshots[displayID] == nil {
            guard let brightness = await readSoftwareBrightness(displayID: displayID) else { continue }
            snapshots[displayID] = brightness
        }

        if dimmed {
            await dimKnownDisplays()
        } else {
            await restoreKnownDisplays()
        }
    }

    func dimKnownDisplays() async {
        guard isExecutableAvailable(executablePath) else { return }
        for displayID in snapshots.keys {
            await setSoftwareBrightness(0, displayID: displayID)
        }
    }

    func restoreKnownDisplays() async {
        guard isExecutableAvailable(executablePath) else {
            snapshots.removeAll()
            return
        }

        for (displayID, brightness) in snapshots {
            await setSoftwareBrightness(brightness, displayID: displayID)
        }
    }

    func restoreAll() async {
        await restoreKnownDisplays()
        snapshots.removeAll()
    }

    private func restoreAndRemove(displayID: CGDirectDisplayID) async {
        guard let brightness = snapshots[displayID] else { return }
        await setSoftwareBrightness(brightness, displayID: displayID)
        snapshots.removeValue(forKey: displayID)
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
