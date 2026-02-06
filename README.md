# MirageKit

MirageKit is a window and desktop streaming framework for Apple platforms. It provides a macOS host service for capturing windows or virtual displays and a client service for discovering hosts, receiving low‑latency video over UDP, and forwarding input back to the host. SwiftUI views are included for rendering streams with Metal on macOS, iOS, and visionOS.

> ⚠️ MirageKit is still in active development and may introduce breaking API updates.

## Features

- Window, app, and full desktop streaming from macOS hosts
- Bonjour discovery with TCP control + UDP video transport
- Peer-to-peer connections over AWDL
- Encoder configuration helpers and per-stream overrides
- Input forwarding (mouse, keyboard, scroll, gestures)
- SwiftUI stream view for macOS, iOS, and visionOS
- Session store + streaming content view for UI state
- Host window + input controllers for macOS integration
- Virtual display capture for pixel‑perfect rendering
- Remote session state + unlock support
- Menu bar passthrough and app‑centric streaming utilities
- Built-in trust store and app preference helpers

## Requirements

- macOS 26+ for host streaming (ScreenCaptureKit)
- iOS 26+ / visionOS 26+ for client streaming
- Swift 6.2+

## Installation

Add MirageKit as a Swift Package Manager dependency.

```swift
// Package.swift
.package(url: "https://github.com/EthanLipnik/MirageKit.git", from: "0.0.1"),
```

MirageKit ships three products:
- `MirageKit` (shared types, protocol, logging)
- `MirageKitClient` (client services + stream views)
- `MirageKitHost` (host services + capture/encode helpers)

Add `MirageKitClient` or `MirageKitHost` to the relevant target dependencies.

## Quick Start

### Host (macOS)

```swift
import MirageKitHost

@MainActor
final class HostController: MirageHostDelegate {
    private let hostService = MirageHostService()

    init() {
        hostService.delegate = self
    }

    func start() async throws {
        try await hostService.start()
    }

    func hostService(_ service: MirageHostService, shouldAllowClient client: MirageConnectedClient, toStreamWindow window: MirageWindow) -> Bool {
        true
    }
}
```

### Client (iOS/macOS/visionOS)

```swift
import MirageKitClient

@MainActor
final class ClientController: MirageClientDelegate {
    let clientService = MirageClientService()

    init() {
        clientService.delegate = self
    }

    func connect(to host: MirageHost) async throws {
        try await clientService.connect(to: host)
        try await clientService.requestWindowList()
    }
}
```

### SwiftUI Stream View

`MirageStreamViewRepresentable` reads frames from `MirageFrameCache` and does not require
SwiftUI state updates per frame.

```swift
import MirageKitClient
import SwiftUI

struct StreamView: View {
    let streamID: StreamID

    var body: some View {
        MirageStreamViewRepresentable(
            streamID: streamID,
            onInputEvent: { event in
                // Forward event to MirageClientService
            },
            onDrawableMetricsChanged: { metrics in
                // Use to request updated capture resolution
            }
        )
    }
}
```

MirageKit also includes a higher-level content view that wires input, focus, and
resize logic to a `MirageClientSessionStore`:

```swift
let sessionStore = MirageClientSessionStore()
let clientService = MirageClientService(sessionStore: sessionStore)

MirageStreamContentView(
    session: session,
    sessionStore: sessionStore,
    clientService: clientService,
    isDesktopStream: false
)
```

## How It Works

- Hosts advertise via Bonjour using `_mirage._tcp` and accept TCP control connections.
- Video payloads stream over UDP; clients register stream IDs to receive data.
- Host encode pipeline: limited in-flight frames with always-latest frame selection.
- The host can create a shared virtual display sized to the client’s display for 1:1 pixels.
- Session state updates allow remote unlock flows (login screen vs locked session).
- Menu bar passthrough enables clients to render native menu structures and send actions back.

## Architecture

For a deeper dive into modules and data flows, see `Architecture.md`.

For ColorSync cleanup guidance, see [If-Your-Computer-Feels-Stuttery.md](If-Your-Computer-Feels-Stuttery.md).

## Configuration

### Encoder Overrides

Clients can supply per-stream overrides with `MirageEncoderOverrides` (keyframe interval, pixel format, color space, capture queue depth, and bitrate). The host applies overrides on top of its `MirageEncoderConfiguration`.

`MirageClientService.runQualityTest()` returns a `MirageQualityTestSummary` that can be used to choose bitrate, pixel format, and resolution limits for your UX.

### Encoder Settings

`MirageEncoderConfiguration` lets you control codec, frame rate, encoder quality, and color space.

- Use `.highQuality` or `.balanced` defaults.
- Use `withOverrides` to apply client-specific intervals or encoder quality.
- Use `withTargetFrameRate` to request the client’s target FPS (60/120 based on display capabilities).
- `frameQuality` targets inter-frame quality and maps to QP bounds when supported.
- `keyframeQuality` targets keyframe quality and should stay below `frameQuality`.

### Networking

`MirageNetworkConfiguration` defines discovery and transport behavior.

- `serviceType` is used for Bonjour discovery.
- `controlPort` (TCP) and `dataPort` (UDP) support explicit or auto-assigned ports (defaults: 9847/9848).
- `enablePeerToPeer` turns on AWDL peer-to-peer discovery and connections.
- `maxPacketSize` controls UDP payload sizing (default stays within IPv6 MTU).

### Streaming Modes

- Window streaming captures a specific window using ScreenCaptureKit.
- Desktop streaming mirrors a virtual display and supports display-sized capture.
- App streaming groups windows by bundle identifier and tracks newly spawned windows.

### Input + UI

- Input events are forwarded via `MirageInputEvent` types (mouse, key, scroll, magnify, rotate).
- `MirageStreamViewRepresentable` renders streams with Metal and exposes drawable size callbacks for resolution sync.
- `MirageStreamContentView` + `MirageClientSessionStore` coordinate input, focus, and resize UI.
- The host uses `MirageHostDelegate` and the client uses `MirageClientDelegate` for approvals and state updates.

## Permissions

The macOS host uses ScreenCaptureKit and may require Screen Recording permission. To forward input or activate windows, the host app may also need Accessibility permission. Clients should have Local Network permission for Bonjour discovery.

## Contributing

Contributions are welcome. Most of this framework was built with agentic coding tools (Claude Code and Codex). Using them is fine as long as you understand and can explain the updates you submit.

## Testing

```bash
swift test
```

## License

MirageKit is licensed under the PolyForm Shield 1.0.0 license. Use, modification, and distribution are allowed for non-competing products; providing products that compete with Mirage or other dedicated remote window/desktop/secondary display/drawing-tablet streaming applications and services is prohibited. See `LICENSE`.
