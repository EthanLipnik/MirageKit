//
//  MirageWireInteractionPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageWire
import Testing

@Suite("MirageWire Interaction Payloads")
struct MirageWireInteractionPayloadTests {
    @Test("Cursor appearance payload round-trips in wire target")
    func cursorAppearancePayloadRoundTripsInWireTarget() throws {
        let message = MirageWire.CursorUpdateMessage(
            streamID: 20,
            cursorType: .resizeNWSE,
            isVisible: true
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .cursorUpdate, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.CursorUpdateMessage.self)

        #expect(decoded.streamID == 20)
        #expect(decoded.cursorType == .resizeNWSE)
        #expect(decoded.cursorType.rawValue == 22)
        #expect(decoded.isVisible)
    }

    @Test("Cursor position payload round-trips in wire target")
    func cursorPositionPayloadRoundTripsInWireTarget() throws {
        let message = MirageWire.CursorPositionUpdateMessage(
            streamID: 21,
            normalizedX: 1.25,
            normalizedY: -0.5,
            isVisible: false
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .cursorPositionUpdate, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.CursorPositionUpdateMessage.self)

        #expect(decoded.streamID == 21)
        #expect(abs(Double(decoded.normalizedX - 1.25)) < 0.0001)
        #expect(abs(Double(decoded.normalizedY - -0.5)) < 0.0001)
        #expect(decoded.isVisible == false)
    }

    @Test("Menu bar payload round-trips in wire target")
    func menuBarPayloadRoundTripsInWireTarget() throws {
        let menuID = try #require(UUID(uuidString: "72000000-0000-0000-0000-000000000001"))
        let itemID = try #require(UUID(uuidString: "72000000-0000-0000-0000-000000000002"))
        let menuBar = MirageWire.MirageMenuBar(
            bundleIdentifier: "com.example.Editor",
            menus: [
                MirageWire.MirageMenu(
                    id: menuID,
                    title: "File",
                    items: [
                        MirageWire.MirageMenuItem(
                            id: itemID,
                            title: "Save",
                            keyboardShortcut: MirageWire.MirageKeyboardShortcut(key: "s", modifiers: [.command]),
                            actionPath: [0, 0]
                        ),
                        .separator(actionPath: [0, 1]),
                    ],
                    menuIndex: 0
                ),
            ],
            version: 99
        )
        let message = MirageWire.MenuBarUpdateMessage(streamID: 22, menuBar: menuBar)
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .menuBarUpdate, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.MenuBarUpdateMessage.self)
        let decodedMenuBar = try #require(decoded.menuBar)
        let decodedFirstItem = try #require(decodedMenuBar.menus.first?.items.first)

        #expect(decoded.streamID == 22)
        #expect(decodedMenuBar.bundleIdentifier == "com.example.Editor")
        #expect(decodedMenuBar.version == 99)
        #expect(decodedMenuBar.menus.first?.id == menuID)
        #expect(decodedFirstItem.id == itemID)
        #expect(decodedFirstItem.keyboardShortcut?.modifiers == [.command])
        #expect(decodedMenuBar.menus.first?.items.last?.isSeparator == true)
    }

    @Test("Menu action payload round-trips in wire target")
    func menuActionPayloadRoundTripsInWireTarget() throws {
        let message = MirageWire.MenuActionRequestMessage(streamID: 22, actionPath: [0, 2, 5])
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .menuActionRequest, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.MenuActionRequestMessage.self)

        #expect(decoded.streamID == 22)
        #expect(decoded.actionPath == [0, 2, 5])
    }

    @Test("Remote client stream option payloads round-trip in wire target")
    func remoteClientStreamOptionPayloadsRoundTripInWireTarget() throws {
        let state = MirageWire.RemoteClientStreamOptionsStateMessage(
            displayMode: .hostMenuBar,
            statusOverlayEnabled: true,
            desktopCursorLockAvailable: true,
            desktopCursorLockMode: .secondaryOnly
        )
        let stateEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .remoteClientStreamOptionsState, content: state).serialize()
        ).message
        let decodedState = try stateEnvelope.decode(MirageWire.RemoteClientStreamOptionsStateMessage.self)

        #expect(decodedState.displayMode == .hostMenuBar)
        #expect(decodedState.statusOverlayEnabled)
        #expect(decodedState.desktopCursorLockAvailable)
        #expect(decodedState.desktopCursorLockMode == .secondaryOnly)

        let cursorPresentation = MirageWire.MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )
        let command = MirageWire.RemoteClientStreamOptionsCommandMessage(
            displayMode: .inStream,
            statusOverlayEnabled: false,
            desktopCursorPresentation: cursorPresentation,
            desktopCursorLockMode: .off,
            stopAppBundleIdentifier: "com.example.Editor",
            stopDesktopStream: true
        )
        let commandEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .remoteClientStreamOptionsCommand, content: command).serialize()
        ).message
        let decodedCommand = try commandEnvelope.decode(MirageWire.RemoteClientStreamOptionsCommandMessage.self)

        #expect(decodedCommand.displayMode == .inStream)
        #expect(decodedCommand.statusOverlayEnabled == false)
        #expect(decodedCommand.desktopCursorPresentation == cursorPresentation)
        #expect(decodedCommand.desktopCursorPresentation?.capturesHostCursor == true)
        #expect(decodedCommand.desktopCursorLockMode == .off)
        #expect(decodedCommand.stopAppBundleIdentifier == "com.example.Editor")
        #expect(decodedCommand.stopDesktopStream == true)
    }
}
