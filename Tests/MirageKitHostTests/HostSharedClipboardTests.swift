//
//  HostSharedClipboardTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import AppKit
import Darwin
import Foundation
import MirageConnectivity
import Testing
import MirageMedia
import MirageWire

@Suite("Host Shared Clipboard", .serialized)
struct HostSharedClipboardTests {
    @Test("Host registers shared clipboard update handler")
    func registersSharedClipboardHandler() async {
        let service = await MainActor.run { MirageHostService(hostName: "Test Host", deviceID: UUID()) }
        await MainActor.run {
            #expect(service.controlMessageHandlers[.sharedClipboardUpdate] != nil)
        }
    }

    @Test("Host shared clipboard requires toggle ready session and active stream")
    func hostSharedClipboardActivationPolicy() {
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: false,
                sessionAvailability: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionAvailability: .credentialsRequired,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionAvailability: .ready,
                hasAppStreams: false,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionAvailability: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionAvailability: .ready,
                hasAppStreams: false,
                hasDesktopStream: true
            )
        )
    }

    @MainActor
    @Test("Host sends automatic shared clipboard payloads during active streams")
    func hostSendsAutomaticSharedClipboardPayloadsDuringActiveStreams() async throws {
        let pasteboardLock = await PasteboardTestLock.acquire()
        defer { pasteboardLock.release() }
        let pasteboardSnapshot = PasteboardSnapshot.capture()
        defer { pasteboardSnapshot.restore() }

        let pair = try await makeLoopbackControlPair()

        async let clientContext = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverContext = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager,
            trustProvider: pair.serverTrustProvider
        )
        _ = try await (clientContext, serverContext)

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value

        do {
            let host = MirageHostService(hostName: "Clipboard Test Host")
            defer { host.sharedClipboardBridge?.setActive(false) }

            let client = MirageConnectedClient(
                id: UUID(),
                name: "Test iPad",
                deviceType: .iPad,
                connectedAt: Date(),
                identityKeyID: "test-client-key"
            )
            let sessionID = pair.server.id
            let hostClientContext = ClientContext(
                sessionID: sessionID,
                client: client,
                controlChannel: serverControl,
                transferEngine: MirageTransferEngine(session: pair.server),
                pathSnapshot: nil
            )
            let mediaSecurityContext = MirageMediaSecurityContext(
                sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength)
            )
            host.connectedClients = [client]
            host.clientsBySessionID[sessionID] = hostClientContext
            host.clientsByID[client.id] = hostClientContext
            host.singleClientSessionID = sessionID
            host.mediaSecurityByClientID[client.id] = mediaSecurityContext
            host.activeStreams = [
                MirageStreamSession(
                    id: 9001,
                    window: MirageMedia.MirageWindow(
                        id: 42,
                        title: "Clipboard Test",
                        application: nil,
                        frame: .zero,
                        isOnScreen: true,
                        windowLayer: 0
                    ),
                    client: client
                )
            ]
            host.sharedClipboardEnabled = true

            try await Task.sleep(for: .milliseconds(350))

            let clipboardText = "Mirage host clipboard \(UUID().uuidString)"
            let receiveTask = Task {
                try await nextControlMessage(from: clientControl, timeout: .seconds(5)) {
                    $0.type == .sharedClipboardUpdate
                }
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboardText, forType: .string)

            let message = try await receiveTask.value
            let update = try message.decode(MirageWire.SharedClipboardUpdateMessage.self)
            let encryptedPayload = try #require(update.encryptedPayload)
            let decryptedPayload = try MirageMediaSecurity.decryptClipboardPayload(
                encryptedPayload,
                context: mediaSecurityContext
            )

            #expect(update.representation.kind == .text)
            #expect(update.chunkIndex == 0)
            #expect(update.chunkCount == 1)
            #expect(String(data: decryptedPayload, encoding: .utf8) == clipboardText)
        } catch {
            await serverControl.cancel()
            await clientControl.cancel()
            await pair.stop()
            throw error
        }

        await serverControl.cancel()
        await clientControl.cancel()
        await pair.stop()
    }
}

private final class PasteboardTestLock {
    private var fileDescriptor: CInt = -1

    private init(fileDescriptor: CInt) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() async -> PasteboardTestLock {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirage-pasteboard-tests.lock")
            .path
        while true {
            let fileDescriptor = open(path, O_CREAT | O_RDWR, 0o600)
            precondition(fileDescriptor >= 0, "Unable to open pasteboard test lock")
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return PasteboardTestLock(fileDescriptor: fileDescriptor)
            }
            close(fileDescriptor)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}

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
#endif
