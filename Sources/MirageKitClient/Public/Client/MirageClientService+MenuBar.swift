//
//  MirageClientService+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Menu bar passthrough requests.
//

import MirageKit

@MainActor
public extension MirageClientService {
    /// Execute a menu action on the host for a specific stream.
    /// - Parameters:
    ///   - streamID: The stream to execute the action on.
    ///   - actionPath: Path to the menu item [menuIndex, itemIndex, submenuIndex, ...].
    /// - Throws: If not connected or message encoding fails.
    func executeMenuAction(streamID: StreamID, actionPath: [Int]) async throws {
        let request = MenuActionRequestMessage(streamID: streamID, actionPath: actionPath)
        try await sendControlMessage(.menuActionRequest, content: request)
    }
}
