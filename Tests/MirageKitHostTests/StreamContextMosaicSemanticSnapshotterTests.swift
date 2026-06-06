//
//  StreamContextMosaicSemanticSnapshotterTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Semantic Snapshotter")
struct StreamContextMosaicSemanticSnapshotterTests {
    @Test("Snapshotter maps focused window and AX child roles into semantic candidates")
    func snapshotterMapsFocusedWindowAndAXChildRolesIntoSemanticCandidates() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 100, y: 50, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 42,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 250, y: 150, width: 900, height: 600),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "scroll",
                            role: "AXScrollArea",
                            frame: CGRect(x: 350, y: 250, width: 500, height: 300)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "toolbar",
                            role: "AXToolbar",
                            frame: CGRect(x: 250, y: 150, width: 900, height: 60)
                        ),
                    ]
                ),
            ]
        )

        let focusedWindow = try #require(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-42")
        })
        let scrollView = try #require(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-42-scroll")
        })
        let toolbar = try #require(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-42-toolbar")
        })

        #expect(focusedWindow.semanticClass == .focusedWindow)
        #expect(focusedWindow.rect == MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200))
        #expect(scrollView.semanticClass == .scrollView)
        #expect(scrollView.codecStrategy == .verticalColumns)
        #expect(scrollView.commitPolicy == .atomic)
        #expect(toolbar.semanticClass == .toolbar)
        #expect(!snapshot.isTransientSystemState)
    }

    @Test("Snapshotter marks Dock transition windows as transient system state")
    func snapshotterMarksDockTransitionWindowsAsTransientSystemState() {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 9,
                    ownerName: "Dock",
                    ownerProcessID: 44,
                    frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
                    layer: 20
                ),
            ]
        )

        #expect(snapshot.isTransientSystemState)
        #expect(snapshot.candidates.first?.semanticClass == .dock)
    }
}
#endif
