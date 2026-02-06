import MirageKit
#if os(macOS)

//
//  UnlockManager+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Helper Methods

    /// Get the current console user
    func getConsoleUser() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        task.arguments = ["-f", "%Su", "/dev/console"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let user = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !user.isEmpty, user != "root" {
                return user
            }
        } catch {
            // Ignore
        }

        return NSUserName()
    }
}

#endif
