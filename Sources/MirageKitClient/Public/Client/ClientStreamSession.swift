//
//  ClientStreamSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream session metadata for client-side UI coordination.
//

import MirageKit
public struct ClientStreamSession: Identifiable, Sendable {
    public let id: StreamID
    public let window: MirageWindow

    public init(id: StreamID, window: MirageWindow) {
        self.id = id
        self.window = window
    }
}
