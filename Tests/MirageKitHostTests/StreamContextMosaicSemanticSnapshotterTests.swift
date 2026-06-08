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
    @Test("Snapshotter maps text and scroll AX roles into semantic candidates")
    func snapshotterMapsTextAndScrollAXRolesIntoSemanticCandidates() throws {
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

        let scrollView = try #require(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-42-scroll")
        })

        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-42")
        })
        #expect(scrollView.semanticClass == .scrollView)
        #expect(scrollView.parentID == MirageMosaicTileID(rawValue: "window-42"))
        #expect(scrollView.codecStrategy == .singleUnit)
        #expect(scrollView.commitPolicy == .atomic)
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-42-toolbar")
        })
        #expect(!snapshot.isTransientSystemState)
    }

    @Test("Snapshotter prefers Xcode-like panes over broad window containers")
    func snapshotterPrefersXcodeLikePanesOverBroadWindowContainers() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 100,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 300, y: 120, width: 900, height: 620),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "toolbar",
                            role: "AXToolbar",
                            frame: CGRect(x: 300, y: 120, width: 900, height: 56)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "navigator",
                            role: "AXOutline",
                            frame: CGRect(x: 315, y: 185, width: 230, height: 470)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "editor",
                            role: "AXScrollArea",
                            frame: CGRect(x: 545, y: 185, width: 520, height: 360)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "console",
                            role: "AXScrollArea",
                            frame: CGRect(x: 545, y: 545, width: 520, height: 180)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "warning-label",
                            role: "AXStaticText",
                            frame: CGRect(x: 555, y: 210, width: 120, height: 20)
                        ),
                    ]
                ),
            ]
        )

        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100")
        })
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-navigator")
        }?.semanticClass == .scrollView)
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-editor")
        }?.semanticClass == .scrollView)
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-console")
        }?.semanticClass == .scrollView)
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100-toolbar")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100-warning-label")
        })
        #expect(snapshot.candidates.count == 3)
    }

    @Test("Snapshotter uses stable IDs for generated AX observations")
    func snapshotterUsesStableIDsForGeneratedAXObservations() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let first = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 100,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 300, y: 120, width: 900, height: 620),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "1-AXScrollArea",
                            role: "AXScrollArea",
                            frame: CGRect(x: 545, y: 185, width: 520, height: 360)
                        ),
                    ]
                ),
            ]
        )
        let second = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 100,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 300, y: 120, width: 900, height: 620),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "4-AXScrollArea",
                            role: "AXScrollArea",
                            frame: CGRect(x: 545, y: 185, width: 520, height: 360)
                        ),
                    ]
                ),
            ]
        )

        let firstCandidate = try #require(first.candidates.first)
        let secondCandidate = try #require(second.candidates.first)
        #expect(firstCandidate.id == secondCandidate.id)
    }

    @Test("Snapshotter marks full-display Dock transition windows as transient without tiling them")
    func snapshotterMarksFullDisplayDockTransitionWindowsAsTransientWithoutTilingThem() {
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
        #expect(snapshot.candidates.isEmpty)
    }

    @Test("Semantic cache returns first snapshot synchronously")
    func semanticCacheReturnsFirstSnapshotSynchronously() throws {
        let cache = StreamContextMosaicSemanticSnapshotCache(
            provider: StaticMosaicSemanticObservationProvider(windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 77,
                    ownerName: "Codex",
                    ownerProcessID: 123,
                    frame: CGRect(x: 100, y: 100, width: 500, height: 400),
                    isFocused: true,
                    isMain: true
                ),
            ]),
            refreshInterval: 60
        )

        let snapshot = cache.snapshot(
            logicalSize: MiragePixelSize(width: 2000, height: 1200),
            captureBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        #expect(snapshot.candidates.isEmpty)
    }
}

private struct StaticMosaicSemanticObservationProvider: StreamContextMosaicSemanticObservationProviding {
    let windows: [StreamContextMosaicSemanticWindowObservation]

    func observations() -> [StreamContextMosaicSemanticWindowObservation] {
        windows
    }
}
#endif
