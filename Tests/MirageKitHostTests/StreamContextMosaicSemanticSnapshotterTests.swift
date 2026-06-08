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
        let toolbar = try #require(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-42-toolbar")
        })

        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-42")
        })
        #expect(scrollView.semanticClass == .scrollView)
        #expect(scrollView.parentID == MirageMosaicTileID(rawValue: "window-42"))
        #expect(scrollView.codecStrategy == .singleUnit)
        #expect(scrollView.commitPolicy == .atomic)
        #expect(toolbar.semanticClass == .toolbar)
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
                            id: "editor-nested-strip",
                            role: "AXScrollArea",
                            frame: CGRect(x: 560, y: 210, width: 120, height: 20)
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
                        StreamContextMosaicSemanticElementObservation(
                            id: "search-field",
                            role: "AXTextField",
                            frame: CGRect(x: 555, y: 245, width: 220, height: 24)
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
        }?.semanticClass == .sidebar)
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-editor")
        }?.semanticClass == .scrollView)
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-console")
        }?.semanticClass == .scrollView)
        #expect(snapshot.candidates.first {
            $0.id == MirageMosaicTileID(rawValue: "window-100-toolbar")
        }?.semanticClass == .toolbar)
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100-editor-nested-strip")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100-warning-label")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-100-search-field")
        })
        #expect(snapshot.candidates.count == 4)
    }

    @Test("Snapshotter ignores background window panes while a focused window is available")
    func snapshotterIgnoresBackgroundWindowPanesWhileFocusedWindowIsAvailable() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 200,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 250, y: 120, width: 950, height: 660),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "editor",
                            role: "AXScrollArea",
                            frame: CGRect(x: 420, y: 190, width: 720, height: 500)
                        ),
                    ]
                ),
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 201,
                    ownerName: "Notes",
                    ownerProcessID: 456,
                    frame: CGRect(x: 30, y: 180, width: 210, height: 520),
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "stage-manager-thumbnail",
                            role: "AXScrollArea",
                            frame: CGRect(x: 40, y: 200, width: 180, height: 480)
                        ),
                    ]
                ),
            ]
        )

        #expect(snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-200-editor")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-201-stage-manager-thumbnail")
        })
        #expect(snapshot.candidates.count == 1)
    }

    @Test("Snapshotter does not let focused system windows suppress app panes")
    func snapshotterDoesNotLetFocusedSystemWindowsSuppressAppPanes() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 250,
                    ownerName: "loginwindow",
                    ownerProcessID: 1,
                    frame: CGRect(x: 0, y: 0, width: 1500, height: 900),
                    layer: 2004,
                    isFocused: true,
                    isMain: true
                ),
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 251,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 250, y: 120, width: 950, height: 660),
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "editor",
                            role: "AXScrollArea",
                            frame: CGRect(x: 420, y: 190, width: 720, height: 500)
                        ),
                    ]
                ),
            ]
        )

        #expect(snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-251-editor")
        })
        #expect(snapshot.candidates.count == 1)
    }

    @Test("Snapshotter rejects text fragments smaller than full viewports")
    func snapshotterRejectsTextFragmentsSmallerThanFullViewports() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 300,
                    ownerName: "Xcode",
                    ownerProcessID: 123,
                    frame: CGRect(x: 200, y: 100, width: 1100, height: 700),
                    isFocused: true,
                    isMain: true,
                    children: [
                        StreamContextMosaicSemanticElementObservation(
                            id: "editor",
                            role: "AXTextArea",
                            frame: CGRect(x: 300, y: 210, width: 850, height: 460)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "single-line-text-area",
                            role: "AXTextArea",
                            frame: CGRect(x: 610, y: 720, width: 520, height: 24)
                        ),
                        StreamContextMosaicSemanticElementObservation(
                            id: "search-field",
                            role: "AXTextField",
                            frame: CGRect(x: 310, y: 130, width: 280, height: 26)
                        ),
                    ]
                ),
            ]
        )

        #expect(snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-300-editor")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-300-single-line-text-area")
        })
        #expect(!snapshot.candidates.contains {
            $0.id == MirageMosaicTileID(rawValue: "window-300-search-field")
        })
        #expect(snapshot.candidates.count == 1)
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

    @Test("Snapshotter maps Dock and menu bar windows into chrome candidates")
    func snapshotterMapsDockAndMenuBarWindowsIntoChromeCandidates() throws {
        let builder = StreamContextMosaicSemanticSnapshotBuilder()
        let snapshot = builder.snapshot(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            captureBounds: CGRect(x: 0, y: 0, width: 1500, height: 900),
            windows: [
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 7,
                    ownerName: "SystemUIServer",
                    ownerProcessID: 50,
                    frame: CGRect(x: 0, y: 0, width: 1500, height: 24),
                    layer: 24
                ),
                StreamContextMosaicSemanticWindowObservation(
                    windowID: 8,
                    ownerName: "Dock",
                    ownerProcessID: 51,
                    frame: CGRect(x: 0, y: 840, width: 1500, height: 60),
                    layer: 20
                ),
            ]
        )

        let menuBar = try #require(snapshot.candidates.first {
            $0.semanticClass == .menuBar
        })
        let dock = try #require(snapshot.candidates.first {
            $0.semanticClass == .dock
        })
        #expect(menuBar.rect == MiragePixelRect(x: 0, y: 0, width: 3000, height: 48))
        #expect(dock.rect == MiragePixelRect(x: 0, y: 1680, width: 3000, height: 120))
        #expect(!snapshot.isTransientSystemState)
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
