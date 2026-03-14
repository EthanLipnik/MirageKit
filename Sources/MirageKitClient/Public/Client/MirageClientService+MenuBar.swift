//
//  MirageClientService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Menu bar passthrough requests.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Execute a menu action on the host for a specific stream.
    /// - Parameters:
    ///   - streamID: The stream to execute the action on.
    ///   - actionPath: Path to the menu item [menuIndex, itemIndex, submenuIndex, ...].
    /// - Throws: If not connected or message encoding fails.
    func executeMenuAction(streamID: StreamID, actionPath: [Int]) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }

        let request = MenuActionRequestMessage(streamID: streamID, actionPath: actionPath)
        try await sendControlMessage(.menuActionRequest, content: request)
    }
}
