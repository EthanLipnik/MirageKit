//
//  HostScreenshotStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Host screenshot destination and filename coverage.
//

#if os(macOS)
import Foundation
@testable import MirageKitHost
import Testing

@Suite("Host Screenshot Store")
struct HostScreenshotStoreTests {
    @Test
    func usesConfiguredScreenshotDirectoryWhenAvailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = try HostScreenshotStore.resolvedDestinationDirectory(
            screenshotLocation: directory.path
        )

        #expect(resolved.standardizedFileURL == directory.standardizedFileURL)
    }

    @Test
    func fallsBackToDesktopForInvalidScreenshotDirectory() throws {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              FileManager.default.fileExists(atPath: desktop.path) else {
            return
        }

        let resolved = try HostScreenshotStore.resolvedDestinationDirectory(
            screenshotLocation: "/tmp/MirageMissingScreenshotDirectory-\(UUID().uuidString)"
        )

        #expect(resolved.standardizedFileURL == desktop.standardizedFileURL)
    }

    @Test
    func uniqueScreenshotURLAvoidsExistingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capturedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let first = HostScreenshotStore.uniqueScreenshotURL(in: directory, capturedAt: capturedAt)
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = HostScreenshotStore.uniqueScreenshotURL(in: directory, capturedAt: capturedAt)

        #expect(second.lastPathComponent.hasSuffix(" 2.png"))
        #expect(second != first)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageHostScreenshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
