//
//  MessageTypes+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Host screenshot request/result message definitions.
//

import Foundation

public enum MirageHostScreenshotStyle: String, Codable, Sendable, Hashable {
    case fullScreen
    case selection
}

public enum MirageHostScreenshotSource: String, Codable, Sendable, Hashable {
    case activeStreamDisplay
    case activeStreamSelection
    case primaryPhysicalDisplay
}

package struct HostScreenshotRequestMessage: Codable, Sendable, Equatable {
    package let requestID: UUID
    package let style: MirageHostScreenshotStyle
    package let streamID: StreamID?

    package init(
        requestID: UUID = UUID(),
        style: MirageHostScreenshotStyle,
        streamID: StreamID? = nil
    ) {
        self.requestID = requestID
        self.style = style
        self.streamID = streamID
    }
}

public struct HostScreenshotResultMessage: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let style: MirageHostScreenshotStyle
    public let success: Bool
    public let source: MirageHostScreenshotSource
    public let filePath: String?
    public let fileName: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let byteCount: UInt64?
    public let displayID: UInt32?
    public let capturedAtMillisecondsSince1970: Int64
    public let errorMessage: String?

    package init(
        requestID: UUID,
        style: MirageHostScreenshotStyle,
        success: Bool,
        source: MirageHostScreenshotSource,
        filePath: String? = nil,
        fileName: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteCount: UInt64? = nil,
        displayID: UInt32? = nil,
        capturedAtMillisecondsSince1970: Int64 = Self.currentMillisecondsSince1970(),
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.style = style
        self.success = success
        self.source = source
        self.filePath = filePath
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.displayID = displayID
        self.capturedAtMillisecondsSince1970 = capturedAtMillisecondsSince1970
        self.errorMessage = errorMessage
    }

    private static func currentMillisecondsSince1970() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
