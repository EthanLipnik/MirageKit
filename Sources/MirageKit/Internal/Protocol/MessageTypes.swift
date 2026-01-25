//
//  MessageTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import CoreGraphics

/// Control channel message types (sent over TCP)
enum ControlMessageType: UInt8, Codable {
    // Connection management
    case hello = 0x01
    case helloResponse = 0x02
    case disconnect = 0x03
    case ping = 0x04
    case pong = 0x05

    // Authentication
    case authRequest = 0x10
    case authChallenge = 0x11
    case authResponse = 0x12
    case authResult = 0x13

    // Window management
    case windowListRequest = 0x20
    case windowList = 0x21
    case windowUpdate = 0x22
    case startStream = 0x23
    case stopStream = 0x24
    case streamStarted = 0x25
    case streamStopped = 0x26
    case streamMetricsUpdate = 0x27

    // Input events
    case inputEvent = 0x30

    // Keyframe control
    case keyframeRequest = 0x42

    // Cursor updates
    case cursorUpdate = 0x50

    // Virtual display updates
    case contentBoundsUpdate = 0x60
    case displayResolutionChange = 0x61
    case streamScaleChange = 0x62
    case streamRefreshRateChange = 0x63

    // Session state and unlock (for headless Mac support)
    case sessionStateUpdate = 0x70
    case unlockRequest = 0x71
    case unlockResponse = 0x72
    case loginDisplayReady = 0x73    // Host -> Client: Login display stream is starting
    case loginDisplayStopped = 0x74  // Host -> Client: Login complete, display stream stopped

    // App-centric streaming (new)
    case appListRequest = 0x80
    case appList = 0x81
    case selectApp = 0x82
    case appStreamStarted = 0x83
    case windowAddedToStream = 0x84
    case windowRemovedFromStream = 0x85
    case windowCooldownStarted = 0x86
    case windowCooldownCancelled = 0x87
    case returnToAppSelection = 0x88
    case closeWindowRequest = 0x89
    case streamPaused = 0x8A
    case streamResumed = 0x8B
    case cancelCooldown = 0x8C
    case windowResizabilityChanged = 0x8D
    case appTerminated = 0x8E

    // Menu bar passthrough
    case menuBarUpdate = 0x90       // Host → Client: Menu structure update
    case menuActionRequest = 0x91   // Client → Host: Execute menu action
    case menuActionResult = 0x92    // Host → Client: Action result

    // Desktop streaming (full virtual display mirroring)
    case startDesktopStream = 0xA0      // Client → Host: Start full desktop stream
    case stopDesktopStream = 0xA1       // Client → Host: Stop desktop stream
    case desktopStreamStarted = 0xA2    // Host → Client: Desktop stream is active
    case desktopStreamStopped = 0xA3    // Host → Client: Desktop stream ended

    // Errors
    case error = 0xFF
}

/// Base control message envelope
struct ControlMessage: Codable {
    let type: ControlMessageType
    let payload: Data

    init(type: ControlMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    init<T: Encodable>(type: ControlMessageType, content: T) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(content)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func deserialize(from data: Data) -> (ControlMessage, Int)? {
        guard data.count >= 5 else { return nil }

        // Use index-relative access for Data that might be a slice
        let startIdx = data.startIndex
        let typeByte = data[startIdx]
        guard let type = ControlMessageType(rawValue: typeByte) else {
            MirageLogger.error(.client, "Unknown control message type byte: 0x\(String(format: "%02X", typeByte))")
            return nil
        }

        // Read length from bytes 1-4 (after the type byte)
        let lengthBytes = data[data.index(startIdx, offsetBy: 1)..<data.index(startIdx, offsetBy: 5)]
        let length = lengthBytes.withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }

        let totalLength = 5 + Int(length)
        guard data.count >= totalLength else { return nil }

        // Extract payload using proper indices
        let payloadStart = data.index(startIdx, offsetBy: 5)
        let payloadEnd = data.index(startIdx, offsetBy: totalLength)
        let payload = Data(data[payloadStart..<payloadEnd])

        return (ControlMessage(type: type, payload: payload), totalLength)
    }
}
