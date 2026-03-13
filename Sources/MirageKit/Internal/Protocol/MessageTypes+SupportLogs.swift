//
//  MessageTypes+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Support log export request/response messages.
//

import Foundation

/// Public host support log archive payload surfaced to Mirage apps.
public struct MirageHostSupportLogArchive: Sendable {
    public let fileName: String
    public let archiveData: Data

    public init(fileName: String, archiveData: Data) {
        self.fileName = fileName
        self.archiveData = archiveData
    }
}

/// Request a zipped support log archive from the connected host (Client -> Host).
package struct HostSupportLogArchiveRequestMessage: Codable {
    package init() {}
}

/// Host support log archive response (Host -> Client).
package struct HostSupportLogArchiveMessage: Codable {
    /// Suggested archive filename, including extension.
    package let fileName: String?
    /// Zipped support log archive payload.
    package let archiveData: Data?
    /// Human-readable failure reason when archive creation was unsuccessful.
    package let errorMessage: String?

    package init(
        fileName: String? = nil,
        archiveData: Data? = nil,
        errorMessage: String? = nil
    ) {
        self.fileName = fileName
        self.archiveData = archiveData
        self.errorMessage = errorMessage
    }
}
