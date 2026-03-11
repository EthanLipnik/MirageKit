//
//  MessageTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

/// Control channel message types (sent over TCP)
package enum ControlMessageType: UInt8, Codable {
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

    /// Input events
    case inputEvent = 0x30

    /// Keyframe control
    case keyframeRequest = 0x42

    /// Cursor updates
    case cursorUpdate = 0x50
    case cursorPositionUpdate = 0x51

    // Virtual display updates
    case contentBoundsUpdate = 0x60
    case displayResolutionChange = 0x61
    case streamScaleChange = 0x62
    case streamRefreshRateChange = 0x63
    case streamEncoderSettingsChange = 0x64

    // Session state and unlock (for headless Mac support)
    case sessionStateUpdate = 0x70
    case unlockRequest = 0x71
    case unlockResponse = 0x72
    case loginDisplayReady = 0x73 // Host -> Client: Login display stream is starting
    case loginDisplayStopped = 0x74 // Host -> Client: Login complete, display stream stopped

    // App-centric streaming (new)
    case appListRequest = 0x80
    case appList = 0x81
    case selectApp = 0x82
    case appStreamStarted = 0x83
    case windowAddedToStream = 0x84
    case windowRemovedFromStream = 0x85
    case windowStreamFailed = 0x86
    case appWindowInventory = 0x87
    case appWindowSwapRequest = 0x88
    case appWindowCloseBlockedAlert = 0x89
    case appWindowCloseAlertActionRequest = 0x8A
    case appWindowCloseAlertActionResult = 0x8B
    case appWindowSwapResult = 0x8C
    case windowResizabilityChanged = 0x8D
    case appTerminated = 0x8E
    case streamPolicyUpdate = 0x8F // Host -> Client: Per-stream runtime tier/fps/bitrate/recovery policy

    // Menu bar passthrough
    case menuBarUpdate = 0x90 // Host → Client: Menu structure update
    case menuActionRequest = 0x91 // Client → Host: Execute menu action
    case menuActionResult = 0x92 // Host → Client: Action result
    case hostHardwareIconRequest = 0x93 // Client -> Host: Request host hardware icon payload
    case hostHardwareIcon = 0x94 // Host -> Client: Host hardware icon payload
    case appIconUpdate = 0x95 // Host -> Client: Incremental app icon payload update
    case appIconStreamComplete = 0x96 // Host -> Client: App icon update stream completion marker

    // Desktop streaming (full virtual display mirroring)
    case startDesktopStream = 0xA0 // Client → Host: Start full desktop stream
    case stopDesktopStream = 0xA1 // Client → Host: Stop desktop stream
    case desktopStreamStarted = 0xA2 // Host → Client: Desktop stream is active
    case desktopStreamStopped = 0xA3 // Host → Client: Desktop stream ended
    case qualityTestRequest = 0xA4 // Client → Host: Run quality test
    case qualityTestResult = 0xA5 // Host → Client: Quality test metadata/result

    // Audio stream lifecycle
    case audioStreamStarted = 0xB0 // Host → Client: Audio stream is active
    case audioStreamStopped = 0xB1 // Host → Client: Audio stream ended
    case hostSoftwareUpdateStatusRequest = 0xB2 // Client -> Host: Request host software update status
    case hostSoftwareUpdateStatus = 0xB3 // Host -> Client: Host software update status snapshot
    case hostSoftwareUpdateInstallRequest = 0xB4 // Client -> Host: Request host software update install
    case hostSoftwareUpdateInstallResult = 0xB5 // Host -> Client: Host software update install result
    case transportRefreshRequest = 0xB6 // Host -> Client: Request immediate UDP re-registration
    case sharedClipboardStatus = 0xB7 // Host -> Client: Shared clipboard runtime state
    case sharedClipboardUpdate = 0xB8 // Host <-> Client: Shared clipboard text update

    /// Errors
    case error = 0xFF
}

/// Base control message envelope
package struct ControlMessage: Codable {
    package let type: ControlMessageType
    package let payload: Data

    package init(type: ControlMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    package init(type: ControlMessageType, content: some Encodable) throws {
        self.type = type
        payload = try JSONEncoder().encode(content)
    }

    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    package func serialize() -> Data {
        var data = Data()
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    package static func deserialize(from data: Data, offset: Int = 0) -> ControlMessageParseResult {
        guard offset >= 0 else {
            return .invalidFrame(reason: "Negative control frame offset \(offset)")
        }
        guard offset <= data.count else {
            return .invalidFrame(reason: "Control frame offset \(offset) exceeds buffer \(data.count)")
        }
        let remaining = data.count - offset
        guard remaining >= 5 else { return .needMoreData }

        let startIdx = data.index(data.startIndex, offsetBy: offset)
        let typeByte = data[startIdx]
        guard let type = ControlMessageType(rawValue: typeByte) else {
            return .invalidFrame(reason: "Unknown control message type byte: 0x\(String(format: "%02X", typeByte))")
        }

        let lengthStart = data.index(startIdx, offsetBy: 1)
        let lengthEnd = data.index(startIdx, offsetBy: 5)
        let lengthBytes = data[lengthStart ..< lengthEnd]
        let payloadLength = lengthBytes.withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }

        let payloadLimit = maxPayloadBytes(for: type)
        let payloadLengthInt = Int(payloadLength)
        if payloadLengthInt > payloadLimit {
            return .invalidFrame(
                reason: "Control payload exceeds limit for \(type): \(payloadLengthInt) > \(payloadLimit)"
            )
        }
        if payloadLengthInt > LoomMessageLimits.maxPayloadBytes,
           payloadLimit < payloadLengthInt {
            return .invalidFrame(
                reason: "Control payload exceeds global limit: \(payloadLengthInt) > \(LoomMessageLimits.maxPayloadBytes)"
            )
        }

        let totalLength = 5 + payloadLengthInt
        if totalLength > LoomMessageLimits.maxFrameBytes {
            return .invalidFrame(
                reason: "Control frame exceeds max bytes: \(totalLength) > \(LoomMessageLimits.maxFrameBytes)"
            )
        }

        guard remaining >= totalLength else { return .needMoreData }

        let payloadStart = data.index(startIdx, offsetBy: 5)
        let payloadEnd = data.index(startIdx, offsetBy: totalLength)
        let payload = Data(data[payloadStart ..< payloadEnd])
        return .success(message: ControlMessage(type: type, payload: payload), bytesConsumed: totalLength)
    }

    private static func maxPayloadBytes(for type: ControlMessageType) -> Int {
        switch type {
        case .appList:
            LoomMessageLimits.maxLargeMetadataPayloadBytes
        case .hostHardwareIcon, .appIconUpdate:
            LoomMessageLimits.maxInlineAssetPayloadBytes
        default:
            LoomMessageLimits.maxPayloadBytes
        }
    }
}

package enum ControlMessageParseResult {
    case success(message: ControlMessage, bytesConsumed: Int)
    case needMoreData
    case invalidFrame(reason: String)
}

package enum ControlMessageParseError: Error {
    case needMoreData
    case invalidFrame(String)
}

package func requireParsedControlMessage(from data: Data, offset: Int = 0) throws -> (ControlMessage, Int) {
    switch ControlMessage.deserialize(from: data, offset: offset) {
    case let .success(message, bytesConsumed):
        return (message, bytesConsumed)
    case .needMoreData:
        throw ControlMessageParseError.needMoreData
    case let .invalidFrame(reason):
        throw ControlMessageParseError.invalidFrame(reason)
    }
}
