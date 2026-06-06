//
//  MirageLogArchiveEntry.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Additional support archive entry included alongside the primary Mirage log.
public struct MirageLogArchiveEntry: Sendable, Equatable {
    /// ZIP entry name.
    public let name: String
    /// Entry payload.
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public init(name: String, text: String) {
        self.init(name: name, data: Data(text.utf8))
    }
}
