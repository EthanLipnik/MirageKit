//
//  MirageHostService+Types.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Public host service supporting types.
//

import Foundation
import MirageKit

#if os(macOS)
public struct MirageConnectedClient: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let deviceType: DeviceType
    public let connectedAt: Date
    public let identityKeyID: String?

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        connectedAt: Date,
        identityKeyID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.connectedAt = connectedAt
        self.identityKeyID = identityKeyID
    }
}

public struct MirageStreamSession: Identifiable, Sendable {
    public let id: StreamID
    public let window: MirageWindow
    public let client: MirageConnectedClient
}
#endif
