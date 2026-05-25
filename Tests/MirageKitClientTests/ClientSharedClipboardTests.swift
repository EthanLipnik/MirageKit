//
//  ClientSharedClipboardTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKitClient
#if os(macOS)
import AppKit
#endif
import Foundation
@testable import MirageKit
import Testing

@Suite("Client Shared Clipboard", .serialized)
struct ClientSharedClipboardTests {
    @Test("Client shared clipboard requires connected host-enabled active streaming")
    func clientSharedClipboardActivationPolicy() {
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .disconnected,
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: false,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: false,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: false,
                hasDesktopStream: true
            )
        )
    }

    @Test("Status handler updates runtime state")
    func sharedClipboardStatusHandlerUpdatesRuntimeState() async throws {
        let enabledMessage = try ControlMessage(
            type: .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: true)
        )

        let service = await MainActor.run {
            let service = MirageClientService(deviceName: "Shared Clipboard Client")
            service.connectionState = .connected(host: "Host")
            return service
        }
        await MainActor.run {
            service.handleSharedClipboardStatus(enabledMessage)
            #expect(service.sharedClipboardEnabled)
        }
    }

    #if os(macOS)
    @MainActor
    @Test("macOS client applies host text updates to the pasteboard")
    func macOSClientAppliesHostTextUpdatesToPasteboard() async {
        let pasteboardSnapshot = PasteboardSnapshot.capture()
        defer { pasteboardSnapshot.restore() }

        NSPasteboard.general.clearContents()

        let bridge = MirageClientSharedClipboardBridge()
        await bridge.setActive(true)

        let clipboardText = "Mirage host clipboard \(UUID().uuidString)"
        await bridge.applyRemoteItem(
            sharedClipboardTextItem(clipboardText),
            orderingToken: sharedClipboardOrderingToken(logicalVersion: 1),
            sentAtMs: 1_000
        )

        #expect(NSPasteboard.general.string(forType: .string) == clipboardText)
        let preparation = await bridge.prepareCurrentClipboardManualSync()
        #expect(preparation == .hostAlreadyCurrent)

        await bridge.setActive(false)
    }

    @MainActor
    @Test("macOS client reads local pasteboard for paste-time sync")
    func macOSClientReadsLocalPasteboardForPasteTimeSync() async {
        let pasteboardSnapshot = PasteboardSnapshot.capture()
        defer { pasteboardSnapshot.restore() }

        let bridge = MirageClientSharedClipboardBridge()
        await bridge.setActive(true)

        let clipboardText = "Mirage client clipboard \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardText, forType: .string)

        switch await bridge.prepareCurrentClipboardManualSync() {
        case let .send(localSend, sentAtMs):
            #expect(localSend.item.representation.kind == .text)
            #expect(localSend.text == clipboardText)
            #expect(sentAtMs > 0)
        case .hostAlreadyCurrent:
            Issue.record("Expected a changed local pasteboard to sync to the host.")
        case nil:
            Issue.record("Expected a changed local pasteboard to produce a sync preparation.")
        }

        await bridge.setActive(false)
    }
    #endif
}

#if os(macOS)
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restoredItems = items.map { storedItem in
            let item = NSPasteboardItem()
            for (type, data) in storedItem {
                item.setData(data, forType: type)
            }
            return item
        }
        guard !restoredItems.isEmpty else { return }
        pasteboard.writeObjects(restoredItems)
    }
}

private extension MirageSharedClipboardLocalSend {
    var text: String? {
        guard let payload = item.payload else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}

private func sharedClipboardTextItem(_ text: String) -> MirageSharedClipboardItem {
    mirageSharedClipboardItem(
        kind: .text,
        contentType: "public.utf8-plain-text",
        filename: nil,
        payload: Data(text.utf8)
    )
}

private func sharedClipboardOrderingToken(logicalVersion: UInt64) -> MirageSharedClipboardOrderingToken {
    MirageSharedClipboardOrderingToken(
        logicalVersion: logicalVersion,
        changeID: UUID()
    )
}
#endif
