//
//  SharedClipboardOpaqueDeclarationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

@testable import MirageKit
import Foundation
import Testing
import MirageWire

extension SharedClipboardTests {
    @Test("Automatic shared clipboard declares each opaque pasteboard change")
    func automaticSharedClipboardDeclaresEachOpaquePasteboardChange() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 0)

        let oversizedFile = opaqueFileItem()
        let first = state.prepareLocalDeclaration(item: oversizedFile, changeCount: 1)
        let duplicateChangeCount = state.prepareLocalDeclaration(item: oversizedFile, changeCount: 1)
        let recopiedOpaqueItem = state.prepareLocalDeclaration(item: oversizedFile, changeCount: 2)

        #expect(first?.item.representation.kind == .file)
        #expect(first?.item.payload == nil)
        #expect(duplicateChangeCount == nil)
        #expect(recopiedOpaqueItem?.item.representation.kind == .file)
        #expect(recopiedOpaqueItem?.item.payload == nil)
        #expect(recopiedOpaqueItem?.orderingToken.logicalVersion == 2)
    }

    @Test("Opaque automatic declarations bypass unattributed remote windows")
    func opaqueAutomaticDeclarationsBypassUnattributedRemoteWindows() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 10)
        let observedAtMs: Int64 = 100_000
        let remoteToken = MirageWire.MirageSharedClipboardOrderingToken(
            logicalVersion: 8,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        )
        state.recordRemoteWrite(
            changeCount: 11,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )

        let declaration = state.prepareLocalDeclaration(
            item: opaqueFileItem(),
            changeCount: 12
        )

        #expect(declaration?.item.representation.kind == .file)
        #expect(declaration?.item.payload == nil)
        #expect(declaration?.orderingToken.logicalVersion == 9)
    }
}

private func opaqueFileItem() -> MirageSharedClipboardItem {
    MirageSharedClipboardItem(
        representation: MirageWire.SharedClipboardRepresentation(
            kind: .file,
            contentType: "public.data",
            filename: "Large.mov",
            byteCount: MirageSharedClipboard.maximumBinaryPayloadBytes + 1
        ),
        payload: nil
    )
}
